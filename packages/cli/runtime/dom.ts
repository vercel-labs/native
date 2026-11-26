import { textRunDependence } from "./text-runs.ts";
// The DOM subset native supports. Anything not declared here is a type error at build time,
// which is how unsupported DOM APIs get reported.
//
// Nodes are real: Node is the base class, Element (and so HTMLElement) a subclass, and Text,
// Comment and DocumentFragment are nodes of their own. Layout, style and paint work on any
// box-shaped node, which for text is the anonymous box its run of text is formatted in.

import * as P from "../shared/props.ts";
import type { DateKind, SegmentDef } from "./date-times.ts";
import {
  dateKindOf, segmentsFor, segmentValues,
  textFromSegments, segmentValueText, segmentMax, adjustSegment,
  sanitizeDateText, dateValueAsNumber, dateTextFromNumber, dateValueOfParts,
  valuePosition, stepValue, stepSize, stepIsAny,
  weekStartDays, monthIndexFromMs, parseDateText, monthFromName,
} from "./date-times.ts";
import { parseSelector, splitTopLevel } from "../shared/css/selectors.ts";
import { capitalizeText } from "../shared/css/case.ts";
import { AC_ACCUMULATE, AC_ADD, AC_REPLACE, packUnit, timingRow, wideCode } from "../shared/css/anim.ts";
import { longhandIds } from "../shared/css/shorthands.ts";
import { parseDeclarationBlock } from "../shared/css/declarations.ts";
import { SYSTEM_COLOR_NAMES, parseColor } from "../shared/css/colors.ts";
import { systemColorValue } from "./system-colors.ts";
import { pathPointAtLength, pathTotalLength } from "./svg-geometry.ts";
import { BAR_FADED, scrollBarState, updateScroll } from "./compositor.ts";
import { noteScroll } from "./app/scrollbar.ts";
import type { Decl, Selector } from "../shared/css/types.ts";
import { CanvasRenderingContext2D, createContext } from "./canvas.ts";
// TexImageSource names ImageData, and a name is a type here only when it is imported: the compiler
// that builds a page has no DOM lib to fall back on.
import type { ImageData } from "./canvas.ts";
import { WebGL2RenderingContext, createWebGL2Context } from "./webgl.ts";
import type { WebGLContextAttributes } from "./webgl.ts";
import { StyleDeclaration, styleView } from "./cssom.ts";
import type { CSSStyleDeclaration } from "./cssom.ts";
import { hostFileRead, hostSetTitle, hostVideoCanPlay, hostWindowFullscreen, hostWindowFullscreenState } from "./host.ts";
import { runEditCommand, supportsEditCommand } from "./editing.ts";
import { followLinkHook } from "./link-hook.ts";
import { runCommandHook } from "./command-hook.ts";
import { ROW_GROUP, ROW_OPTION, closeSelectPopup, openSelectPopup, selectPopupSerial } from "./select-popup.ts";
import type { SelectPopupRow } from "./select-popup.ts";
import { isQuirks } from "./quirk.ts";
import { decodedImageNow, imageId, imageSizeById, resolveImageSource, whenImageReady } from "./images.ts";
import { borderBottom, borderTop, display, isReplaced, len, measure, scriptScrollsX, scriptScrollsY, zeroIfNaN, padV } from "./layout/box-model.ts";
import { appendedSubtreeStylesAlone, restyleForState, fontBoxHeight, fontBoxLeading, computeStyles, fontKey, lineAlign, lineHeightPx, selectorMatches, usedWritingMode } from "./style.ts";
import { letterSpacingPx, spacingPx, textWidth, wordSpacingPx } from "./layout/text.ts";
import { dirty, invalidateStyle, invalidateStyleOf, invalidateLayout, invalidatePaint, markFullPaint, markPaintDirty, markPaintRects, stateUsage, textVersion, LAYOUT_SELF, boxChanges, markLayoutDirty, noteBoxKindChanged, noteClassChange, noteOtherIdentityChange, noteStructureChange } from "./invalidation.ts";
import { ADOPTED, getSheetFonts, refreshSheet, refreshSubtree, refreshTextOwner, setCompiledSheetMediaByIndex, setCompiledSheetOffByIndex } from "./sheets.ts";
import type { CSSStyleSheet } from "./sheets.ts";
import { viewport } from "./viewport.ts";
import { stickyShiftHook } from "./sticky-hook.ts";
import { pointHitsHook } from "./point-hook.ts";
import { flushLayoutHook } from "./layout-flush-hook.ts";
import { cancelSmoothScrollHook, smoothScrollHook } from "./smooth-hook.ts";
import { snapScrollPositionHook } from "./snap-hook.ts";
import { Animation, KeyframeEffect, KeyframeRun, cancelTransitionOnDetach, elementAnimations, startScriptRun } from "./animation.ts";
export { KeyframeEffect };
export type { ComputedEffectTiming, EffectTiming, KeyframeAnimationOptions } from "./animation.ts";
import type { KeyframeAnimationOptions } from "./animation.ts";
import type { Location, Window } from "./window.ts";

export { dirty, invalidateStyle, invalidateStyleOf, invalidateLayout, invalidatePaint, markFullPaint, markPaintDirty };

import { Event, CustomEvent, MessageEvent, trusted, eventTypeArg, eventInitArg, dictBool, dictString } from "./events.ts";
import type { EventInit, PathItem, CustomEventInit } from "./events.ts";
export { Event, CustomEvent, MessageEvent, trusted, eventTypeArg, eventInitArg, dictBool, dictString };
export type { EventInit, PathItem, CustomEventInit };
// The style-sheet classes a script builds and reads, re-exported with the DOM that owns them.
export { CSSRule, CSSCounterStyleRule, CSSMediaRule, CSSStyleSheet, MediaList } from "./sheets.ts";

// Public API of the style object; re-exported here so user code finds it with the DOM.
export { getComputedStyle } from "./cssom.ts";
// Canvas types user code names, re-exported for the same reason.
export type { CanvasGradient, CanvasRenderingContext2D, TextMetrics } from "./canvas.ts";
export { WebGL2RenderingContext };
export type { WebGLContextAttributes, WebGLBuffer, WebGLTexture, WebGLFramebuffer,
  WebGLRenderbuffer, WebGLProgram, WebGLShader, WebGLVertexArrayObject, WebGLUniformLocation,
  WebGLActiveInfo, WebGLShaderPrecisionFormat } from "./webgl.ts";

/** A listener function, called with the event and the target as its `this`. */
export type EventListener = (event: Event) => void;

/** How many nodes the runtime has made: it orders two nodes in different trees (see Node.serial). */
let nodeSerial = 0;
/** The object form of a listener: addEventListener() takes these too. */
export interface EventListenerObject {
  handleEvent(event: Event): void;
}
export type EventListenerOrEventListenerObject = EventListener | EventListenerObject;
/** The runtime's name for a function listener. */
export type Listener = EventListener;

/** One keyframe a script writes: an offset and the properties it moves. */
export type Keyframe = Record<string, any>;
/** Keyframes written as one object mapping each property to its list of values. */
export type PropertyIndexedKeyframes = Record<string, any>;
/** What getAnimations() takes: ask for the descendants' animations as well. */
export interface GetAnimationsOptions {
  subtree?: boolean;
}

// The objects getAnimations() reports, re-exported so user code finds them with the DOM.
export type { Animation } from "./animation.ts";

/**
 * Every event native dispatches, and the base of the specific kinds below. The constructor takes
 * the DOM's (type, init) form; dispatch() sets target and walks the tree from there.
 */
/** The event a listener is running for, as the legacy `window.event` reports it. */
export let currentEvent: Event | null = null;

export interface UIEventInit extends EventInit {
  detail?: number;
}

/** An event from a view: a click, a key press, a scroll. Its `detail` counts something. */
export class UIEvent extends Event {
  get [Symbol.toStringTag](): string { return "UIEvent"; }
  readonly detail: number;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    this.detail = dictLong(eventInitArg(args), "detail", 0);
  }
}

export interface MouseEventInit extends UIEventInit {
  screenX?: number;
  screenY?: number;
  clientX?: number;
  clientY?: number;
  movementX?: number;
  movementY?: number;
  button?: number;
  buttons?: number;
  relatedTarget?: Node | null;
  ctrlKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

/** A pointer event with the mouse fields: position in the viewport, and the buttons/modifiers. */
export class MouseEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "MouseEvent"; }
  readonly screenX: number;
  readonly screenY: number;
  readonly clientX: number;
  readonly clientY: number;
  readonly movementX: number;
  readonly movementY: number;
  readonly button: number;
  readonly buttons: number;
  /** The node the pointer came from or went to, retargeted for the listener reading it. */
  get relatedTarget(): Node | null {
    return this.relatedNow;
  }
  clearTargets(): void {
    super.clearTargets();
    this.relatedNow = null;
  }
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly altKey: boolean;
  readonly metaKey: boolean;

  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.screenX = dictDouble(init, "screenX", 0);
    this.screenY = dictDouble(init, "screenY", 0);
    this.clientX = dictDouble(init, "clientX", 0);
    this.clientY = dictDouble(init, "clientY", 0);
    this.movementX = dictDouble(init, "movementX", 0);
    this.movementY = dictDouble(init, "movementY", 0);
    this.button = dictLong(init, "button", 0);
    this.buttons = dictUnsignedLong(init, "buttons", 0);
    this.relatedSource = dictNode(init, "relatedTarget");
    this.relatedNow = this.relatedSource;
    this.ctrlKey = dictBool(init, "ctrlKey", false);
    this.shiftKey = dictBool(init, "shiftKey", false);
    this.altKey = dictBool(init, "altKey", false);
    this.metaKey = dictBool(init, "metaKey", false);
  }
  /**
   * Where the pointer is inside the target's box, which is what a drag on a control measures.
   * The target is the element the event reached, so a listener on an ancestor measures from the
   * element under the pointer, as a browser does.
   */
  get offsetX(): number {
    return offsetIn(this, true);
  }
  get offsetY(): number {
    return offsetIn(this, false);
  }
  getModifierState(key: string): boolean {
    if (key === "Control") return this.ctrlKey;
    if (key === "Shift") return this.shiftKey;
    if (key === "Alt") return this.altKey;
    if (key === "Meta") return this.metaKey;
    return false;
  }
}

/** A mouse event's position inside its target's box; the viewport position when it has no box. */
function offsetIn(event: MouseEvent, horizontal: boolean): number {
  const t = event.target;
  if (t instanceof Element) {
    const r = t.getBoundingClientRect();
    return horizontal ? event.clientX - r.left : event.clientY - r.top;
  }
  return horizontal ? event.clientX : event.clientY;
}

export interface PointerEventInit extends MouseEventInit {
  pointerId?: number;
  width?: number;
  height?: number;
  pressure?: number;
  tangentialPressure?: number;
  tiltX?: number;
  tiltY?: number;
  twist?: number;
  pointerType?: string;
  isPrimary?: boolean;
}

/** A pointer event, which for our purposes is a mouse with an id and a pressure. */
export class PointerEvent extends MouseEvent {
  get [Symbol.toStringTag](): string { return "PointerEvent"; }
  readonly pointerId: number;
  readonly width: number;
  readonly height: number;
  readonly pressure: number;
  readonly tangentialPressure: number;
  readonly tiltX: number;
  readonly tiltY: number;
  readonly twist: number;
  readonly pointerType: string;
  readonly isPrimary: boolean;

  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.pointerId = dictLong(init, "pointerId", 0);
    this.width = dictDouble(init, "width", 1);
    this.height = dictDouble(init, "height", 1);
    this.pressure = dictDouble(init, "pressure", 0);
    this.tangentialPressure = dictDouble(init, "tangentialPressure", 0);
    this.tiltX = dictLong(init, "tiltX", 0);
    this.tiltY = dictLong(init, "tiltY", 0);
    this.twist = dictLong(init, "twist", 0);
    this.pointerType = dictString(init, "pointerType", "");
    this.isPrimary = dictBool(init, "isPrimary", false);
  }
  /**
   * The pointer events this one stands for. The host reports each move as it comes, so there are
   * never any it held back: the event is the whole of its own movement.
   */
  getCoalescedEvents(): PointerEvent[] {
    return [this];
  }
}

export interface KeyboardEventInit extends EventInit {
  key?: string;
  code?: string;
  location?: number;
  repeat?: boolean;
  isComposing?: boolean;
  ctrlKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
  charCode?: number;
  keyCode?: number;
}

/** A key event, with the key's name and the physical key's code. */
export class KeyboardEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "KeyboardEvent"; }
  static readonly DOM_KEY_LOCATION_STANDARD = 0;
  static readonly DOM_KEY_LOCATION_LEFT = 1;
  static readonly DOM_KEY_LOCATION_RIGHT = 2;
  static readonly DOM_KEY_LOCATION_NUMPAD = 3;

  readonly key: string;
  readonly code: string;
  readonly location: number;
  readonly repeat: boolean;
  readonly isComposing: boolean;
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly altKey: boolean;
  readonly metaKey: boolean;
  readonly charCode: number;
  readonly keyCode: number;

  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.key = dictString(init, "key", "");
    this.code = dictString(init, "code", "");
    this.location = dictUnsignedLong(init, "location", 0);
    this.repeat = dictBool(init, "repeat", false);
    this.isComposing = dictBool(init, "isComposing", false);
    this.ctrlKey = dictBool(init, "ctrlKey", false);
    this.shiftKey = dictBool(init, "shiftKey", false);
    this.altKey = dictBool(init, "altKey", false);
    this.metaKey = dictBool(init, "metaKey", false);
    this.charCode = dictUnsignedLong(init, "charCode", 0);
    this.keyCode = dictUnsignedLong(init, "keyCode", 0);
  }
  getModifierState(key: string): boolean {
    if (key === "Control") return this.ctrlKey;
    if (key === "Shift") return this.shiftKey;
    if (key === "Alt") return this.altKey;
    if (key === "Meta") return this.metaKey;
    return false;
  }
}

export interface InputEventInit extends UIEventInit {
  data?: string | null;
  inputType?: string;
  isComposing?: boolean;
}

/** The event a text field fires as its value changes. */
export class InputEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "InputEvent"; }
  readonly data: string | null;
  readonly inputType: string;
  readonly isComposing: boolean;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.data = dictStringOrNull(init, "data");
    this.inputType = dictString(init, "inputType", "");
    this.isComposing = dictBool(init, "isComposing", false);
  }
}

export interface FocusEventInit extends UIEventInit {
  relatedTarget?: Node | null;
}

/** The event focus and blur fire with: the element focus went to or came from. */
export class FocusEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "FocusEvent"; }
  /** The node focus came from or went to, retargeted for the listener reading it. */
  get relatedTarget(): Node | null {
    return this.relatedNow;
  }
  clearTargets(): void {
    super.clearTargets();
    this.relatedNow = null;
  }
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    this.relatedSource = dictNode(eventInitArg(args), "relatedTarget");
    this.relatedNow = this.relatedSource;
  }
}

export interface SubmitEventInit extends EventInit {
  submitter?: Element | null;
}

/** The event a form fires when a submit button (or Enter) submits it. */
export class SubmitEvent extends Event {
  get [Symbol.toStringTag](): string { return "SubmitEvent"; }
  readonly submitter: Element | null;
  constructor(type: string, init: SubmitEventInit = {}) {
    super(type, init);
    this.submitter = init.submitter === undefined ? null : init.submitter;
  }
}

export interface ToggleEventInit extends EventInit {
  newState?: string;
  oldState?: string;
  /** The element that caused the change: an invoker's command, or null for a script. */
  source?: Element | null;
}

/** The event a popover fires as it opens and closes. */
export class ToggleEvent extends Event {
  get [Symbol.toStringTag](): string { return "ToggleEvent"; }
  readonly newState: string;
  readonly oldState: string;
  readonly source: Element | null;
  constructor(type: string, init: ToggleEventInit = {}) {
    super(type, init);
    this.newState = init.newState === undefined ? "" : init.newState;
    this.oldState = init.oldState === undefined ? "" : init.oldState;
    this.source = init.source === undefined ? null : init.source;
  }
}

/** The event a media query fires when its result changes. It is declared here, beside the other
 *  event classes, rather than in runtime/window.ts with the MediaQueryList that dispatches it:
 *  window belongs to an import cycle (window → cssom → animation → dom), and a class in a cycle
 *  cannot extend a class from another module of it, because the base class may not have run yet.
 *  Declared after Event, in Event's own module, it has one initialisation order to satisfy. */
export class MediaQueryListEvent extends Event {
  get [Symbol.toStringTag](): string { return "MediaQueryListEvent"; }
  readonly matches: boolean;
  readonly media: string;
  constructor(type: string, init: { matches?: boolean; media?: string } = {}) {
    super(type, {});
    this.matches = init.matches === true;
    this.media = init.media === undefined ? "" : init.media;
  }
}

export interface WheelEventInit extends MouseEventInit {
  deltaX?: number;
  deltaY?: number;
  deltaZ?: number;
  deltaMode?: number;
}

/** A wheel event, with the scroll distance it asks for. */
export class WheelEvent extends MouseEvent {
  get [Symbol.toStringTag](): string { return "WheelEvent"; }
  static readonly DOM_DELTA_PIXEL = 0;
  static readonly DOM_DELTA_LINE = 1;
  static readonly DOM_DELTA_PAGE = 2;

  readonly deltaX: number;
  readonly deltaY: number;
  readonly deltaZ: number;
  readonly deltaMode: number;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.deltaX = dictDouble(init, "deltaX", 0);
    this.deltaY = dictDouble(init, "deltaY", 0);
    this.deltaZ = dictDouble(init, "deltaZ", 0);
    this.deltaMode = dictUnsignedLong(init, "deltaMode", 0);
  }
}

// ---------------------------------------------------------------------------
// Drag and drop, clipboard and touch
//
// These event classes are declared for parity with a browser on a desktop: a Mac without a
// touchscreen still declares TouchEvent, and a page's listeners for these events are simply never
// called, because the host's input is a mouse and a keyboard. A script can make them itself, and
// the payload the drag and clipboard events carry is real.

/** One entry in a drag's or a paste's payload: a string format, or a file. */
export class DataTransferItem {
  get [Symbol.toStringTag](): string { return "DataTransferItem"; }
  /** "string" for a format the payload holds text for, "file" for a file it carries. */
  readonly kind: string;
  /** The MIME type, or "" when the payload doesn't name one. */
  readonly type: string;
  private readonly file: File | null;

  constructor(kind: string, type: string, file: File | null = null) {
    this.kind = kind;
    this.type = type;
    this.file = file;
  }

  /** The file behind a "file" item; null for a string item. */
  getAsFile(): File | null {
    return this.file;
  }
}

/**
 * What a drag or a paste carries. A script can build one (`new DataTransfer()`) and hand it to an
 * event it makes; the formats are kept lowercased except for the case-insensitive "Text" alias,
 * as a browser keeps them.
 */
export class DataTransfer {
  get [Symbol.toStringTag](): string { return "DataTransfer"; }
  /** What a drop is allowed to do here: "none" until a handler says otherwise. */
  dropEffect: string = "none";
  /** What the drag started out allowing; "uninitialized" when nothing set it. */
  effectAllowed: string = "uninitialized";
  private formats: string[] = [];
  private data: string[] = [];
  /** The files the payload carries: the ones a drag from outside the app dropped, or ones a
   *  script put in as it made the payload. */
  files: File[] = [];

  /**
   * The MIME types the payload holds strings for, in the order they were set, with "Files" first
   * when it carries files, as a browser lists them.
   */
  get types(): string[] {
    if (this.files.length === 0) return this.formats.slice();
    const out = ["Files"];
    for (const f of this.formats) out.push(f);
    return out;
  }

  /** The entries the payload holds: its files first, then its string formats. */
  get items(): DataTransferItem[] {
    const out: DataTransferItem[] = [];
    for (const f of this.files) out.push(new DataTransferItem("file", f.type, f));
    for (const t of this.formats) out.push(new DataTransferItem("string", t));
    return out;
  }

  getData(format: string): string {
    const i = this.formats.indexOf(format.toLowerCase());
    return i < 0 ? "" : this.data[i];
  }

  setData(format: string, value: string): void {
    const f = format.toLowerCase();
    const i = this.formats.indexOf(f);
    if (i < 0) {
      this.formats.push(f);
      this.data.push(value);
    } else {
      this.data[i] = value;
    }
  }

  clearData(format: string = ""): void {
    if (format === "") {
      this.formats = [];
      this.data = [];
      return;
    }
    const i = this.formats.indexOf(format.toLowerCase());
    if (i < 0) return;
    this.formats.splice(i, 1);
    this.data.splice(i, 1);
  }

  /** The image a drag shows under the pointer. There is no drag image to set here. */
  setDragImage(element: Element | null, x: number, y: number): void {
  }
}

export interface DragEventInit extends MouseEventInit {
  dataTransfer?: DataTransfer | null;
}

/** A drag lifecycle event (dragstart, dragover, drop, ...). */
export class DragEvent extends MouseEvent {
  get [Symbol.toStringTag](): string { return "DragEvent"; }
  readonly dataTransfer: DataTransfer | null;
  constructor(type: string, init: DragEventInit = {}) {
    super(type, init);
    this.dataTransfer = init.dataTransfer === undefined ? null : init.dataTransfer;
  }
}

/** The event a page gets when it asks whether the window may unload. */
export class BeforeUnloadEvent extends Event {
  get [Symbol.toStringTag](): string { return "BeforeUnloadEvent"; }
  constructor(type: string) {
    super(type, {});
  }
}

/** A device motion reading (window events only; the app's host has no motion sensor). */
export class DeviceMotionEvent extends Event {
  get [Symbol.toStringTag](): string { return "DeviceMotionEvent"; }
  readonly interval: number = 0;
  constructor(type: string, init: { interval?: number } = {}) {
    super(type, {});
    this.interval = init.interval === undefined ? 0 : init.interval;
  }
}

/** A device orientation reading (window events only; the app's host has no compass). */
export class DeviceOrientationEvent extends Event {
  get [Symbol.toStringTag](): string { return "DeviceOrientationEvent"; }
  readonly alpha: number | null = null;
  readonly beta: number | null = null;
  readonly gamma: number | null = null;
  absolute = false;
  constructor(type: string, init: { alpha?: number | null; beta?: number | null; gamma?: number | null; absolute?: boolean } = {}) {
    super(type, {});
    this.alpha = init.alpha === undefined ? null : init.alpha;
    this.beta = init.beta === undefined ? null : init.beta;
    this.gamma = init.gamma === undefined ? null : init.gamma;
    this.absolute = init.absolute === true;
  }
}

export interface HashChangeEventInit extends EventInit {
  oldURL?: string;
  newURL?: string;
}

/** The fragment changing: the address before and after. */
export class HashChangeEvent extends Event {
  get [Symbol.toStringTag](): string { return "HashChangeEvent"; }
  readonly oldURL: string;
  readonly newURL: string;
  constructor(type: string, init: HashChangeEventInit = {}) {
    super(type, init);
    this.oldURL = init.oldURL === undefined ? "" : init.oldURL;
    this.newURL = init.newURL === undefined ? "" : init.newURL;
  }
}

export interface MessageEventInit extends EventInit {
  data?: any;
  origin?: string;
  lastEventId?: string;
  /** The window the message came from: a WindowProxy, or null for a message this page posted to
   *  itself. */
  source?: any;
}

export interface CommandEventInit extends EventInit {
  command?: string;
  source?: Element | null;
}

/**
 * An invoker's command: `command` is the name the invoker asked for, `--`-prefixed for a page's own
 * (as the Invoker Commands API spells them), and `source` the element that asked. A menuitem with
 * a command fires it when it is clicked, and the platform runs the commands it knows.
 */
export class CommandEvent extends Event {
  get [Symbol.toStringTag](): string { return "CommandEvent"; }
  readonly command: string;
  readonly source: Element | null;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.command = dictString(init, "command", "");
    const source = dictNode(init, "source");
    this.source = source instanceof Element ? source : null;
  }
}

export interface StorageEventInit extends EventInit {
  key?: string | null;
  oldValue?: string | null;
  newValue?: string | null;
  url?: string;
}

/** A change to one of the storage areas. */
export class StorageEvent extends Event {
  get [Symbol.toStringTag](): string { return "StorageEvent"; }
  readonly key: string | null;
  readonly oldValue: string | null;
  readonly newValue: string | null;
  readonly url: string;
  constructor(type: string, init: StorageEventInit = {}) {
    super(type, init);
    this.key = init.key === undefined ? null : init.key;
    this.oldValue = init.oldValue === undefined ? null : init.oldValue;
    this.newValue = init.newValue === undefined ? null : init.newValue;
    this.url = init.url === undefined ? "" : init.url;
  }
}

export interface TextEventInit extends UIEventInit {
  data?: string;
}

/** The legacy text input event; input events superseded it. */
export class TextEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "TextEvent"; }
  readonly data: string;
  constructor(type: string, init: TextEventInit = {}) {
    super(type, init);
    this.data = init.data === undefined ? "" : init.data;
  }
}

export interface ClipboardEventInit extends EventInit {
  clipboardData?: DataTransfer | null;
}

/** A copy, cut or paste event, with what the clipboard holds. */
export class ClipboardEvent extends Event {
  get [Symbol.toStringTag](): string { return "ClipboardEvent"; }
  readonly clipboardData: DataTransfer | null;
  constructor(type: string, init: ClipboardEventInit = {}) {
    super(type, init);
    this.clipboardData = init.clipboardData === undefined ? null : init.clipboardData;
  }
}

export interface CompositionEventInit extends UIEventInit {
  data?: string;
}

/** An input method event (compositionstart, compositionupdate, compositionend). */
export class CompositionEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "CompositionEvent"; }
  readonly data: string;
  constructor(type: string, init: CompositionEventInit = {}) {
    super(type, init);
    this.data = init.data === undefined ? "" : init.data;
  }
}

export interface TouchInit {
  identifier?: number;
  target?: EventTarget | null;
  clientX?: number;
  clientY?: number;
  pageX?: number;
  pageY?: number;
  screenX?: number;
  screenY?: number;
  radiusX?: number;
  radiusY?: number;
  rotationAngle?: number;
  force?: number;
}

/** One finger on a screen: where it is, and which touch it is over the gesture's life. */
export class Touch {
  get [Symbol.toStringTag](): string { return "Touch"; }
  readonly identifier: number;
  readonly target: EventTarget | null;
  readonly clientX: number;
  readonly clientY: number;
  readonly pageX: number;
  readonly pageY: number;
  readonly screenX: number;
  readonly screenY: number;
  readonly radiusX: number;
  readonly radiusY: number;
  readonly rotationAngle: number;
  readonly force: number;

  constructor(init: TouchInit = {}) {
    this.identifier = init.identifier === undefined ? 0 : init.identifier;
    this.target = init.target === undefined ? null : init.target;
    this.clientX = init.clientX === undefined ? 0 : init.clientX;
    this.clientY = init.clientY === undefined ? 0 : init.clientY;
    this.pageX = init.pageX === undefined ? this.clientX : init.pageX;
    this.pageY = init.pageY === undefined ? this.clientY : init.pageY;
    this.screenX = init.screenX === undefined ? this.clientX : init.screenX;
    this.screenY = init.screenY === undefined ? this.clientY : init.screenY;
    this.radiusX = init.radiusX === undefined ? 0 : init.radiusX;
    this.radiusY = init.radiusY === undefined ? 0 : init.radiusY;
    this.rotationAngle = init.rotationAngle === undefined ? 0 : init.rotationAngle;
    this.force = init.force === undefined ? 0 : init.force;
  }
}

/** The touches on a screen: an array here, so indexing, length and the array methods all work. */
export type TouchList = readonly Touch[];

export interface TouchEventInit extends UIEventInit {
  touches?: Touch[];
  targetTouches?: Touch[];
  changedTouches?: Touch[];
  altKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  shiftKey?: boolean;
}

/** A touch event, with the touches on the screen and the ones that changed. */
export class TouchEvent extends UIEvent {
  get [Symbol.toStringTag](): string { return "TouchEvent"; }
  readonly touches: TouchList;
  readonly targetTouches: TouchList;
  readonly changedTouches: TouchList;
  readonly altKey: boolean;
  readonly ctrlKey: boolean;
  readonly metaKey: boolean;
  readonly shiftKey: boolean;

  constructor(type: string, init: TouchEventInit = {}) {
    super(type, init);
    this.touches = init.touches === undefined ? [] : init.touches;
    this.targetTouches = init.targetTouches === undefined ? this.touches : init.targetTouches;
    this.changedTouches = init.changedTouches === undefined ? [] : init.changedTouches;
    this.altKey = init.altKey === true;
    this.ctrlKey = init.ctrlKey === true;
    this.metaKey = init.metaKey === true;
    this.shiftKey = init.shiftKey === true;
  }
}

export interface AnimationEventInit extends EventInit {
  animationName?: string;
  elapsedTime?: number;
  pseudoElement?: string;
  animation?: Animation | null;
}

/** One nullable DOMString member: absent or null is null, anything else a string. */
export function dictStringOrNull(init: any, name: string): string | null {
  const v = init[name];
  if (v === undefined || v === null) return null;
  return String(v);
}

/** One double member: WebIDL's ToNumber, which throws a TypeError for a non-finite result (NaN,
 *  an infinity, or a value that can't convert). */
export function dictDouble(init: any, name: string, fallback: number): number {
  const v = init[name];
  if (v === undefined) return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new TypeError("The provided double value is non-finite.");
  return n;
}

/** One long member: ToNumber, truncated toward zero and wrapped into the signed 32-bit range. */
export function dictLong(init: any, name: string, fallback: number): number {
  const v = init[name];
  if (v === undefined) return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  const t = Math.trunc(n) % 4294967296;
  return t >= 2147483648 ? t - 4294967296 : t < -2147483648 ? t + 4294967296 : t;
}

/** One unsigned long member: ToNumber wrapped into the unsigned 32-bit range. */
export function dictUnsignedLong(init: any, name: string, fallback: number): number {
  const v = init[name];
  if (v === undefined) return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  const t = Math.trunc(n) % 4294967296;
  return t < 0 ? t + 4294967296 : t;
}

/** One Node member (relatedTarget and the like): absent or null is null. */
export function dictNode(init: any, name: string): Node | null {
  const v = init[name];
  if (v === undefined || v === null) return null;
  if (v instanceof Node) return v;
  throw new TypeError("The provided value is not of type 'Node'.");
}

/** One Animation member (the animation an event was made for): absent or null is null. */
export function dictAnimation(init: any, name: string): Animation | null {
  const v = init[name];
  if (v === undefined || v === null) return null;
  if (v instanceof Animation) return v;
  throw new TypeError("The provided value is not of type 'Animation'.");
}

/** An animation lifecycle event (animationstart, animationend, ...). */
export class AnimationEvent extends Event {
  get [Symbol.toStringTag](): string { return "AnimationEvent"; }
  readonly animationName: string;
  readonly elapsedTime: number;
  readonly pseudoElement: string;
  readonly animation: Animation | null;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.animationName = dictString(init, "animationName", "");
    this.elapsedTime = dictDouble(init, "elapsedTime", 0);
    this.pseudoElement = dictString(init, "pseudoElement", "");
    this.animation = dictAnimation(init, "animation");
  }
}

export interface TransitionEventInit extends EventInit {
  propertyName?: string;
  elapsedTime?: number;
  pseudoElement?: string;
  animation?: Animation | null;
}

/** A transitionend-style event. */
export class TransitionEvent extends Event {
  get [Symbol.toStringTag](): string { return "TransitionEvent"; }
  readonly propertyName: string;
  readonly elapsedTime: number;
  readonly pseudoElement: string;
  readonly animation: Animation | null;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.propertyName = dictString(init, "propertyName", "");
    this.elapsedTime = dictDouble(init, "elapsedTime", 0);
    this.pseudoElement = dictString(init, "pseudoElement", "");
    this.animation = dictAnimation(init, "animation");
  }
}

/** The options addEventListener() takes, as a dictionary or the boolean `capture` form. */
export interface ListenerOptions {
  capture?: boolean;
  once?: boolean;
  passive?: boolean;
}
export type AddEventListenerOptions = ListenerOptions;
export type EventListenerOptions = ListenerOptions;

/** One listener with its options, kept in the order it was added. */
export class ListenerEntry {
  get [Symbol.toStringTag](): string { return "ListenerEntry"; }
  /** A function listener, called with the node as `this`. */
  fn: EventListener | null;
  /** An object listener, whose handleEvent() is called. */
  object: EventListenerObject | null;
  capture: boolean;
  once: boolean;
  passive: boolean;
  constructor(fn: EventListener | null, object: EventListenerObject | null, capture: boolean,
    once: boolean, passive: boolean) {
    this.fn = fn;
    this.object = object;
    this.capture = capture;
    this.once = once;
    this.passive = passive;
  }
}

function listenerEntry(listener: EventListenerOrEventListenerObject,
  options?: ListenerOptions | boolean): ListenerEntry {
  const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
  const once = typeof options === "boolean" || options === undefined ? false : options.once === true;
  const passive = typeof options === "boolean" || options === undefined ? false : options.passive === true;
  if (typeof listener === "function") return new ListenerEntry(listener, null, capture, once, passive);
  return new ListenerEntry(null, listener, capture, once, passive);
}

/**
 * Runs the listeners on `node`, in the order they were added. `capture` picks the capture
 * listeners (true), the ones that run while the event bubbles (false), or all of them (null,
 * at the target, where a listener runs in the phase it was added for but in add order).
 */
function invokeListeners(list: ListenerEntry[] | undefined, node: Node, event: Event, capture: boolean | null): void {
  if (list === undefined) return;
  const snapshot = list.slice();
  for (const entry of snapshot) {
    if (capture !== null && entry.capture !== capture) continue;
    if (entry.once) {
      const i = list.indexOf(entry);
      if (i >= 0) list.splice(i, 1);
    }
    event.currentTarget = node;
    event.passiveListener = entry.passive;
    if (entry.fn !== null) entry.fn.call(node, event);
    else if (entry.object !== null) entry.object.handleEvent(event);
    event.passiveListener = false;
    if (event.immediateStopped) return;
  }
}

/**
 * The event types an element listens for, with the event class each one arrives as. The map is
 * what types a listener's parameter: addEventListener("click", (e) => ...) gives e a MouseEvent,
 * and a handler written for the specific kind of event fits wherever a listener is taken.
 */
export interface GlobalEventHandlersEventMap {
  abort: Event;
  animationcancel: AnimationEvent;
  animationend: AnimationEvent;
  animationiteration: AnimationEvent;
  animationstart: AnimationEvent;
  auxclick: MouseEvent;
  beforeinput: InputEvent;
  blur: FocusEvent;
  cancel: Event;
  canplay: Event;
  canplaythrough: Event;
  change: Event;
  click: MouseEvent;
  close: Event;
  command: CommandEvent;
  compositionend: CompositionEvent;
  compositionstart: CompositionEvent;
  compositionupdate: CompositionEvent;
  contextmenu: MouseEvent;
  copy: ClipboardEvent;
  cut: ClipboardEvent;
  dblclick: MouseEvent;
  drag: DragEvent;
  dragend: DragEvent;
  dragenter: DragEvent;
  dragleave: DragEvent;
  dragover: DragEvent;
  dragstart: DragEvent;
  drop: DragEvent;
  durationchange: Event;
  emptied: Event;
  ended: Event;
  error: Event;
  focus: FocusEvent;
  focusin: FocusEvent;
  focusout: FocusEvent;
  formdata: Event;
  gotpointercapture: PointerEvent;
  input: InputEvent;
  invalid: Event;
  keydown: KeyboardEvent;
  keypress: KeyboardEvent;
  keyup: KeyboardEvent;
  load: Event;
  loadeddata: Event;
  loadedmetadata: Event;
  loadstart: Event;
  lostpointercapture: PointerEvent;
  mousedown: MouseEvent;
  mouseenter: MouseEvent;
  mouseleave: MouseEvent;
  mousemove: MouseEvent;
  mouseout: MouseEvent;
  mouseover: MouseEvent;
  mouseup: MouseEvent;
  paste: ClipboardEvent;
  pause: Event;
  play: Event;
  playing: Event;
  pointercancel: PointerEvent;
  pointerdown: PointerEvent;
  pointerenter: PointerEvent;
  pointerleave: PointerEvent;
  pointermove: PointerEvent;
  pointerout: PointerEvent;
  pointerover: PointerEvent;
  pointerup: PointerEvent;
  progress: Event;
  ratechange: Event;
  reset: Event;
  resize: UIEvent;
  scroll: Event;
  scrollend: Event;
  seeked: Event;
  seeking: Event;
  select: Event;
  selectionchange: Event;
  stalled: Event;
  submit: SubmitEvent;
  suspend: Event;
  timeupdate: Event;
  toggle: ToggleEvent;
  touchcancel: TouchEvent;
  touchend: TouchEvent;
  touchmove: TouchEvent;
  touchstart: TouchEvent;
  transitioncancel: TransitionEvent;
  transitionend: TransitionEvent;
  transitionrun: TransitionEvent;
  transitionstart: TransitionEvent;
  volumechange: Event;
  waiting: Event;
  wheel: WheelEvent;
}
export interface HTMLElementEventMap extends GlobalEventHandlersEventMap {}
export interface ElementEventMap extends HTMLElementEventMap {}
export interface DocumentEventMap extends GlobalEventHandlersEventMap {}
/** The events a window hears: the page's own, and the life the app's shell gives it. */
export interface WindowEventMap extends GlobalEventHandlersEventMap {
  beforeunload: BeforeUnloadEvent;
  hashchange: HashChangeEvent;
  message: MessageEvent;
  move: UIEvent;
  pagehide: Event;
  pageshow: Event;
  popstate: Event;
  storage: StorageEvent;
  unhandledrejection: Event;
  rejectionhandled: Event;
}

/**
 * The event surface every target has. The first overload of each listener method types the
 * listener by the event type it names, as the DOM does, so a MouseEvent handler fits "click".
 */
/**
 * The event target a script makes with `new EventTarget()`: listeners, and events dispatched at
 * the object itself. Nodes and the window have their own tree-shaped dispatch; this one has no
 * path, so every listener it holds runs at the target in the order it was added.
 */
export class EventTarget {
  listeners: Map<string, ListenerEntry[]> = new Map();
  addEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K,
    listener: (event: GlobalEventHandlersEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    if (listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    let list = this.listeners.get(type);
    if (list === undefined) {
      list = [];
      this.listeners.set(type, list);
    }
    for (const entry of list) {
      if (entry.capture === capture &&
        ((entry.fn !== null && entry.fn === listener) || (entry.object !== null && entry.object === listener))) return;
    }
    list.push(listenerEntry(listener, options));
  }
  removeEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K,
    listener: (event: GlobalEventHandlersEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    const list = this.listeners.get(type);
    if (list === undefined || listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    for (let i = 0; i < list.length; i++) {
      const entry = list[i];
      const same = entry.fn !== null ? entry.fn === listener : entry.object === listener;
      if (same && entry.capture === capture) {
        list.splice(i, 1);
        return;
      }
    }
  }
  dispatchEvent(event: Event): boolean {
    if (!(event instanceof Event)) throw new TypeError("Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    event.dispatchFlag = true;
    event.propagationStopped = false;
    event.immediateStopped = false;
    event.setDispatchTargets(this, this);
    // The legacy window.event is the event while its listeners run, as for a node's dispatch.
    const outerEvent = currentEvent;
    currentEvent = event;
    event.eventPhase = Event.AT_TARGET;
    const list = this.listeners.get(event.type);
    if (list !== undefined) {
      const snapshot = list.slice();
      for (const entry of snapshot) {
        if (entry.once) {
          const at = list.indexOf(entry);
          if (at >= 0) list.splice(at, 1);
        }
        event.passiveListener = entry.passive;
        if (entry.fn !== null) entry.fn.call(this as any, event);
        else if (entry.object !== null) entry.object.handleEvent(event);
        event.passiveListener = false;
        if (event.immediateStopped) break;
      }
    }
    event.eventPhase = Event.NONE;
    event.setDispatchTargets(this, null);
    currentEvent = outerEvent;
    event.dispatchFlag = false;
    event.propagationStopped = false;
    event.immediateStopped = false;
    return !event.defaultPrevented;
  }
}

/** The names a class attribute holds, parsed once per distinct string: a re-rendered row writes
 *  the same class text on every frame, and the attribute is otherwise static. */
const classNameLists: Map<string, string[]> = new Map();

function classNamesOf(value: string): string[] {
  const hit = classNameLists.get(value);
  if (hit !== undefined) return hit;
  const names: string[] = [];
  for (const n of value.split(" ")) if (n !== "" && names.indexOf(n) < 0) names.push(n);
  if (classNameLists.size > 512) classNameLists.clear();
  classNameLists.set(value, names);
  return names;
}

export class DOMTokenList {
  get [Symbol.toStringTag](): string { return "DOMTokenList"; }
  private names: string[] = [];
  /** The element the list belongs to, so a change can tell whether it is in the document yet. */
  owner: Element | null = null;

  /** A class change moves the cascade of the page the element is in; a detached element has no
   *  styled box yet — insertion works its subtree's style out then — so it asks for nothing. */
  private changed(): void {
    if (this.owner === null) invalidateStyle();
    else if (this.owner.isConnected) invalidateStyleOf(this.owner);
    // An element created by script keeps the rules it matched when it was made. A class it gains
    // later names rules that were never in that set, so ask the style pass to work them out again,
    // as the id setter does for an id. A compiled element's rules already cover every class a
    // script can add, since the build keeps them all.
    if (this.owner !== null && this.owner.dynamic) this.owner.rulesStale = true;
    if (liveHead !== null) refreshLiveCollections();
  }

  /** Replaces the whole list from a space-separated string (className / class attribute). */
  setValue(value: string): void {
    const names = classNamesOf(value);
    // Writing the list the element already carries changes nothing: a virtual list re-applies the
    // same class text to every mounted row each frame.
    if (names.length === this.names.length) {
      let same = true;
      for (let i = 0; i < names.length; i++) if (names[i] !== this.names[i]) { same = false; break; }
      if (same) return;
    }
    const before = this.names;
    this.names = names.slice();
    const owner = this.owner;
    // A class a rule could name on an ancestor changes what the element's descendants match; the
    // tokens that came and went are what the style engine checks (see style.ts). An element not
    // in the document has no styled subtree yet: inserting it styles the subtree from scratch.
    if (owner !== null && owner.isConnected) {
      const changed: string[] = [];
      for (const n of before) if (this.names.indexOf(n) < 0) changed.push(n);
      for (const n of this.names) if (before.indexOf(n) < 0) changed.push(n);
      if (changed.length > 0) noteClassChange(owner, changed);
    }
    this.changed();
  }

  /**
   * A token the spec refuses: the empty string is a SyntaxError, and one holding ASCII
   * whitespace is an InvalidCharacterError. The runtime has no DOMException class, so the name
   * leads the message, as the other DOM errors put it.
   */
  private valid(token: string, method: string): void {
    if (token === "") {
      throw new Error(`SyntaxError: Failed to execute '${method}' on 'DOMTokenList': The token provided must not be empty.`);
    }
    if (/[\t\n\f\r ]/.test(token)) {
      throw new Error(`InvalidCharacterError: Failed to execute '${method}' on 'DOMTokenList': The token provided ('${token}') contains HTML space characters, which are not valid in tokens.`);
    }
  }

  /** Adds each token not already in the list, as `classList.add("a", "b")` does. */
  add(...tokens: string[]): void {
    const added: string[] = [];
    for (const token of tokens) {
      this.valid(token, "add");
      if (this.names.indexOf(token) < 0) {
        this.names.push(token);
        added.push(token);
      }
    }
    if (added.length === 0) return;
    // A rule may name a class on an ancestor; the style engine checks the tokens that came and went.
    if (this.owner !== null && this.owner.isConnected) noteClassChange(this.owner, added);
    this.changed();
  }
  /** Removes each token the list holds, in one pass. */
  remove(...tokens: string[]): void {
    const removed: string[] = [];
    for (const token of tokens) {
      this.valid(token, "remove");
      const i = this.names.indexOf(token);
      if (i >= 0) {
        this.names.splice(i, 1);
        removed.push(token);
      }
    }
    if (removed.length === 0) return;
    if (this.owner !== null && this.owner.isConnected) noteClassChange(this.owner, removed);
    this.changed();
  }
  /** The tokens as the list holds them, for the style engine's rule index. */
  tokens(): string[] {
    return this.names;
  }

  contains(token: string): boolean {
    this.valid(token, "contains");
    return this.names.indexOf(token) >= 0;
  }
  /**
   * Turns a token on or off and reports the state it ends in. A `force` argument makes the call
   * set that state, so the token is added or removed whatever it held.
   */
  toggle(token: string, force?: boolean): boolean {
    this.valid(token, "toggle");
    const has = this.names.indexOf(token) >= 0;
    const want = force === undefined ? !has : force;
    if (want && !has) this.add(token);
    else if (!want && has) this.remove(token);
    return want;
  }
  /** Swaps one token for another, keeping its place, and reports whether it was there to swap. */
  replace(token: string, newToken: string): boolean {
    this.valid(token, "replace");
    this.valid(newToken, "replace");
    const i = this.names.indexOf(token);
    if (i < 0) return false;
    // The token goes when the new one is already there, even when they are the same token, as
    // the DOM's own replace() has it.
    const changed = this.names.indexOf(newToken) >= 0 ? [token] : [token, newToken];
    if (this.names.indexOf(newToken) >= 0) this.names.splice(i, 1);
    else this.names[i] = newToken;
    if (this.owner !== null && this.owner.isConnected) noteClassChange(this.owner, changed);
    this.changed();
    return true;
  }
  /** Every token type is supported, since a class list takes any token at all. */
  supports(token: string): boolean {
    this.valid(token, "supports");
    return true;
  }
  get length(): number {
    return this.names.length;
  }
  get value(): string {
    return this.names.join(" ");
  }
  item(index: number): string | null {
    return index >= 0 && index < this.names.length ? this.names[index] : null;
  }
  toString(): string {
    return this.value;
  }
}

// ---------------------------------------------------------------------------
// Attributes

/** One attribute: its name and the text it holds. */
export class Attr {
  get [Symbol.toStringTag](): string { return "Attr"; }
  readonly name: string;
  readonly localName: string;
  readonly namespaceURI: string | null;
  readonly prefix: string | null;
  readonly ownerElement: Element | null;
  /** The document that made this attribute node; null for one made by the page's own tree. */
  ownerDoc: Document | null = null;
  value: string;

  constructor(name: string, value: string, owner: Element | null, namespaceURI: string | null = null,
    prefix: string | null = null, localName: string = "") {
    this.name = name;
    this.localName = localName === "" ? name : localName;
    this.ownerElement = owner;
    this.namespaceURI = namespaceURI;
    this.prefix = prefix;
    this.value = value;
  }
  get ownerDocument(): Document | null {
    return this.ownerDoc !== null ? this.ownerDoc : document;
  }
  get specified(): boolean {
    return true;
  }
  get nodeName(): string {
    return this.name;
  }
  get nodeValue(): string {
    return this.value;
  }
  set nodeValue(value: string) {
    this.value = value;
  }
  /** A copy of the attribute node, namespaces included. */
  cloneNode(_deep: boolean = false): Attr {
    const copy = new Attr(this.name, this.value, null, this.namespaceURI, this.prefix, this.localName);
    copy.ownerDoc = this.ownerDoc;
    return copy;
  }
  /** An attribute's text is its value. */
  get textContent(): string {
    return this.value;
  }
  set textContent(value: string) {
    this.value = value;
  }
}

/**
 * An element's attributes, as `el.attributes` hands them out: a list of Attr that can also be
 * looked up by name. Reading the list takes a fresh copy of the element's attributes; the
 * setNamedItem and removeNamedItem methods change the element itself.
 */
export class NamedNodeMap extends Array<Attr> {
  get [Symbol.toStringTag](): string { return "NamedNodeMap"; }
  private readonly owner: Element;

  constructor(owner: Element) {
    super();
    this.owner = owner;
    for (const name of owner.attributeNames()) {
      const attr = owner.getAttributeNode(name);
      if (attr !== null) this.push(attr);
    }
  }
  item(index: number): Attr | null {
    return index >= 0 && index < this.length ? this[index] : null;
  }
  getNamedItem(name: string): Attr | null {
    for (const attr of this) if (attr.name === name) return attr;
    return null;
  }
  setNamedItem(attr: Attr): Attr | null {
    const old = this.getNamedItem(attr.name);
    this.owner.setAttribute(attr.name, attr.value);
    return old;
  }
  removeNamedItem(name: string): Attr {
    const old = this.getNamedItem(name);
    if (old === null) throw new Error("NotFoundError: no attribute named " + name);
    this.owner.removeAttribute(name);
    return old;
  }
}

// ---------------------------------------------------------------------------
// MutationObserver

export interface MutationObserverInit {
  childList?: boolean;
  attributes?: boolean;
  characterData?: boolean;
  subtree?: boolean;
  attributeFilter?: string[];
  attributeOldValue?: boolean;
  characterDataOldValue?: boolean;
}

/** One change a MutationObserver reports: child list edits, an attribute, or text data. */
export class MutationRecord {
  get [Symbol.toStringTag](): string { return "MutationRecord"; }
  type: string;
  target: Node;
  addedNodes: Node[] = [];
  removedNodes: Node[] = [];
  previousSibling: Node | null = null;
  nextSibling: Node | null = null;
  attributeName: string | null = null;
  attributeNamespace: string | null = null;
  oldValue: string | null = null;

  constructor(type: string, target: Node) {
    this.type = type;
    this.target = target;
  }
}

/** Every observer that is observing something, so a mutation can skip the walk when none is. */
const OBSERVERS: MutationObserver[] = [];
let deliverQueued = false;

export class MutationObserver {
  get [Symbol.toStringTag](): string { return "MutationObserver"; }
  private callback: (records: MutationRecord[], observer: MutationObserver) => void;
  private targets: Node[] = [];
  private options: MutationObserverInit[] = [];
  private queue: MutationRecord[] = [];

  constructor(callback: (records: MutationRecord[], observer: MutationObserver) => void) {
    this.callback = callback;
  }

  observe(target: Node, options?: MutationObserverInit): void {
    const init: MutationObserverInit = options === undefined ? {} : options;
    const i = this.targets.indexOf(target);
    if (i < 0) {
      this.targets.push(target);
      this.options.push(init);
    } else {
      this.options[i] = init;
    }
    if (OBSERVERS.indexOf(this) < 0) OBSERVERS.push(this);
  }

  disconnect(): void {
    this.targets = [];
    this.options = [];
    this.queue = [];
    const i = OBSERVERS.indexOf(this);
    if (i >= 0) OBSERVERS.splice(i, 1);
  }

  takeRecords(): MutationRecord[] {
    const records = this.queue;
    this.queue = [];
    return records;
  }

  /**
   * Every registration of this observer that sees `node` for this kind of change. One observer
   * gets one record per change even when several of its registrations match, and the record
   * carries the old value when any of them asked for it.
   */
  private watching(node: Node, kind: string, name: string | null): { created: boolean; oldValue: boolean } | null {
    let created = false;
    let oldValue = false;
    for (let i = 0; i < this.targets.length; i++) {
      const target = this.targets[i];
      const init = this.options[i];
      const inside = target !== node && init.subtree === true && target.contains(node);
      if (target !== node && !inside) continue;
      if (kind === "childList" && init.childList !== true) continue;
      if (kind === "attributes") {
        if (init.attributes !== true) continue;
        if (init.attributeFilter !== undefined && name !== null && init.attributeFilter.indexOf(name) < 0) continue;
        if (init.attributeOldValue === true) oldValue = true;
      }
      if (kind === "characterData") {
        if (init.characterData !== true) continue;
        if (init.characterDataOldValue === true) oldValue = true;
      }
      created = true;
    }
    return created ? { created: true, oldValue: oldValue } : null;
  }

  private enqueue(record: MutationRecord): void {
    this.queue.push(record);
    if (!deliverQueued) {
      deliverQueued = true;
      Promise.resolve().then(deliverMutations);
    }
  }

  /** Hands the queued records to the callback, as the microtask a browser uses does. */
  deliver(): void {
    const records = this.queue;
    this.queue = [];
    if (records.length > 0) this.callback(records, this);
  }

  // The DOM's mutation points call these. Each one hands the record to every observer that
  // watches the target for that kind of change.

  noteChildList(target: Node, added: Node[], removed: Node[], previousSibling: Node | null = null,
    nextSibling: Node | null = null): void {
    if (OBSERVERS.length === 0 || (added.length === 0 && removed.length === 0)) return;
    for (const observer of OBSERVERS) {
      const init = observer.watching(target, "childList", null);
      if (init === null) continue;
      const record = new MutationRecord("childList", target);
      record.addedNodes = added;
      record.removedNodes = removed;
      record.previousSibling = previousSibling;
      record.nextSibling = nextSibling;
      observer.enqueue(record);
    }
  }

  noteAttribute(target: Element, name: string, oldValue: string | null): void {
    if (OBSERVERS.length === 0) return;
    for (const observer of OBSERVERS) {
      const init = observer.watching(target, "attributes", name);
      if (init === null) continue;
      const record = new MutationRecord("attributes", target);
      record.attributeName = name;
      record.attributeNamespace = null;
      record.oldValue = init.oldValue ? oldValue : null;
      observer.enqueue(record);
    }
  }

  noteCharacterData(target: Node, oldValue: string): void {
    if (OBSERVERS.length === 0) return;
    for (const observer of OBSERVERS) {
      const init = observer.watching(target, "characterData", null);
      if (init === null) continue;
      const record = new MutationRecord("characterData", target);
      record.oldValue = init.oldValue ? oldValue : null;
      observer.enqueue(record);
    }
  }
}

/** One shared observer for the DOM's mutation points, which only enqueues for the real ones. */
const mutationRelay = new MutationObserver(() => {});

function noteChildList(target: Node, added: Node[], removed: Node[], previousSibling: Node | null = null,
  nextSibling: Node | null = null): void {
  // A node that moved may inherit a different language. Only the moved subtrees can see a
  // different answer, so their caches are dropped rather than the whole page's: a list that
  // fills a few rows each frame would otherwise make every text run walk its ancestors again.
  if (shadowTrees > 0) {
    langVersion++;
  } else {
    for (const n of added) dropLangCache(n);
    for (const n of removed) dropLangCache(n);
  }
  // Layout reads the children through the flat list a style pass settles (boxKids), so a child
  // list that changed without a pass has to drop it.
  target.flat = null;
  if (OBSERVERS.length > 0) mutationRelay.noteChildList(target, added, removed, previousSibling, nextSibling);
  markLayoutDirty(target);
  // A positioned box taken out grew the scroll extents of the boxes it was in.
  for (const r of removed) if (holdsPositioned(r)) boxChanges.growthStale = true;
  // The live getElements* lists read the tree, which has just changed.
  if (liveHead !== null) refreshLiveCollections();
}
/** Whether a subtree holds a box incremental layout counts as positioned. */
function holdsPositioned(n: Node): boolean {
  if (n.lInOof) return true;
  for (const c of n.kids) if (holdsPositioned(c)) return true;
  return false;
}
function noteAttribute(target: Element, name: string, oldValue: string | null): void {
  // An attribute can move a used value an element kind depends on (an input's type, a picture's
  // source), so what display() remembered for this element is dropped.
  target.dispGen = -1;
  // A language attribute the tree inherits from moved every node under it.
  if (name === "lang" || name === "xml:lang") langVersion++;
  if (OBSERVERS.length > 0) mutationRelay.noteAttribute(target, name, oldValue);
  // A class list written with the value it had (a list's rows filled again each update) changes
  // nothing layout reads; any other attribute only gets here when its value moved.
  const same = name === "class" && target.classList.value === (oldValue === null ? "" : oldValue);
  if (!same) {
    markLayoutDirty(target);
    // A class or id reaches layout through the style it selects, which the style pass compares
    // (noteLayoutInputs); any other attribute can be one layout reads itself (rows, src, colspan).
    if (name !== "class" && name !== "id") {
      target.lOwnChanged = true;
      noteBoxKindChanged(target);
    }
  }
  notifyAttribute(target, name, oldValue);
  // Only these attributes decide which lists an element belongs to or answers for.
  if (liveHead !== null && (name === "id" || name === "class" || name === "name")) refreshLiveCollections();
}
function noteCharacterData(target: Node, oldValue: string): void {
  if (OBSERVERS.length > 0) mutationRelay.noteCharacterData(target, oldValue);
  markLayoutDirty(target);
}

function deliverMutations(): void {
  deliverQueued = false;
  for (const observer of OBSERVERS.slice()) observer.deliver();
}

// ---------------------------------------------------------------------------
// ResizeObserver

/** One side of a box: the inline and block sizes of the array forms in ResizeObserverEntry. */
export class ResizeObserverSize {
  get [Symbol.toStringTag](): string { return "ResizeObserverSize"; }
  readonly inlineSize: number;
  readonly blockSize: number;

  constructor(inlineSize: number, blockSize: number) {
    this.inlineSize = inlineSize;
    this.blockSize = blockSize;
  }
}

/** An element's size after layout, as a ResizeObserver callback receives it. */
export class ResizeObserverEntry {
  get [Symbol.toStringTag](): string { return "ResizeObserverEntry"; }
  readonly target: Element;
  /** The content box: what padding and borders leave inside the border box. */
  readonly contentRect: DOMRect;
  readonly contentBoxSize: ResizeObserverSize[];
  readonly borderBoxSize: ResizeObserverSize[];

  constructor(target: Element, contentRect: DOMRect, borderW: number, borderH: number) {
    this.target = target;
    this.contentRect = contentRect;
    this.contentBoxSize = [new ResizeObserverSize(contentRect.width, contentRect.height)];
    this.borderBoxSize = [new ResizeObserverSize(borderW, borderH)];
  }
}

const RESIZE_OBSERVERS: ResizeObserver[] = [];

/**
 * Watches elements' content boxes: after each layout pass, an element whose size changed since
 * the last callback arrives in one. The first callback after observe() reports the current size,
 * as a browser's does.
 */
export class ResizeObserver {
  get [Symbol.toStringTag](): string { return "ResizeObserver"; }
  private callback: (entries: ResizeObserverEntry[], observer: ResizeObserver) => void;
  private targets: Element[] = [];
  /** The size last reported for each target; -1 before the first callback. */
  private widths: number[] = [];
  private heights: number[] = [];

  constructor(callback: (entries: ResizeObserverEntry[], observer: ResizeObserver) => void) {
    this.callback = callback;
  }

  observe(target: Element): void {
    if (this.targets.indexOf(target) >= 0) return;
    this.targets.push(target);
    this.widths.push(-1);
    this.heights.push(-1);
    if (RESIZE_OBSERVERS.indexOf(this) < 0) RESIZE_OBSERVERS.push(this);
  }

  unobserve(target: Element): void {
    const i = this.targets.indexOf(target);
    if (i < 0) return;
    this.targets.splice(i, 1);
    this.widths.splice(i, 1);
    this.heights.splice(i, 1);
    if (this.targets.length === 0) {
      const j = RESIZE_OBSERVERS.indexOf(this);
      if (j >= 0) RESIZE_OBSERVERS.splice(j, 1);
    }
  }

  disconnect(): void {
    this.targets = [];
    this.widths = [];
    this.heights = [];
    const i = RESIZE_OBSERVERS.indexOf(this);
    if (i >= 0) RESIZE_OBSERVERS.splice(i, 1);
  }

  /** Hands the callback the elements whose content box changed since it last ran. */
  deliver(): void {
    const entries: ResizeObserverEntry[] = [];
    for (let i = 0; i < this.targets.length; i++) {
      const el = this.targets[i];
      const w = el.contentW;
      const h = el.contentH;
      if (w === this.widths[i] && h === this.heights[i]) continue;
      this.widths[i] = w;
      this.heights[i] = h;
      entries.push(new ResizeObserverEntry(el, new DOMRect(el.contentX, el.contentY, w, h), el.w, el.h));
    }
    if (entries.length > 0) this.callback(entries, this);
  }
}

/** Runs after a layout pass: hands each observer the elements whose size changed. */
export function deliverResizeObservers(): void {
  if (RESIZE_OBSERVERS.length === 0) return;
  for (const observer of RESIZE_OBSERVERS.slice()) observer.deliver();
}

// ---------------------------------------------------------------------------
// dataset

/** The attribute a dataset key names: `fooBar` is `data-foo-bar`. */
function dataAttr(key: string): string {
  let name = "data-";
  for (let i = 0; i < key.length; i++) {
    const c = key[i];
    const upper = c >= "A" && c <= "Z";
    name += upper ? "-" + c.toLowerCase() : c;
  }
  return name;
}

/** The dataset key an attribute names: `data-foo-bar` is `fooBar`. */
function dataKey(attr: string): string {
  let key = "";
  let up = false;
  for (let i = 5; i < attr.length; i++) {
    const c = attr[i];
    if (c === "-") up = true;
    else {
      key += up ? c.toUpperCase() : c;
      up = false;
    }
  }
  return key;
}

/** The dataset views made so far, one per element. */
const DATASETS = new WeakMap<Element, any>();

/** The live view of an element's data-* attributes. The traps are untyped because scriptc
 *  refuses typed trap signatures, and the target and the result are untyped because it can't
 *  yet return a native Proxy as a dictionary; each trap maps a key to its attribute. */
/** A dataset's name→attribute conversion: an upper-case letter becomes `-` and lower case. */
function datasetAttr(key: string): string | null {
  for (let i = 0; i < key.length - 1; i++) {
    if (key[i] === "-" && key[i + 1] >= "a" && key[i + 1] <= "z") return null;
  }
  let out = "data-";
  for (const ch of key) {
    if (ch >= "A" && ch <= "Z") out += "-" + ch.toLowerCase();
    else out += ch;
  }
  return out;
}

/** An attribute name→dataset key conversion: null when the name isn't exposed in the dataset. */
function datasetKey(attr: string): string | null {
  if (attr.length <= 5 || attr.slice(0, 5) !== "data-") return null;
  const rest = attr.slice(5);
  for (let i = 0; i < rest.length - 1; i++) {
    if (rest[i] === "-" && rest[i + 1] >= "a" && rest[i + 1] <= "z") return null;
  }
  let out = "";
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "-" && i + 1 < rest.length) {
      out += rest[i + 1].toUpperCase();
      i++;
    } else out += rest[i];
  }
  return out;
}

/** The DOMStringMap interface a dataset is an instance of (its methods are the proxy's traps). */
export class DOMStringMap {
  get [Symbol.toStringTag](): string { return "DOMStringMap"; }
}

export /** A title's text with runs of ASCII white space folded to one space and the edges trimmed. */
function foldTitle(text: string): string {
  return text.replace(/[ \t\n\r\f]+/g, " ").replace(/^ | $/g, "");
}

export function makeDataset(el: Element): any {
  const made = DATASETS.get(el);
  if (made !== undefined) return made;
  const view = new Proxy({} as any, {
    get(_t: any, key: string): any {
      const attr = datasetAttr(key);
      if (attr === null) return undefined;
      const v = el.getAttribute(attr);
      return v === null ? undefined : v;
    },
    set(_t: any, key: string, value: any): any {
      const attr = datasetAttr(key);
      if (attr === null) throw new Error("SyntaxError: Failed to set a named property on 'DOMStringMap': '" + key + "' is not a valid property name.");
      if (!/^[^\s"'>\/=]+$/.test(attr)) {
        throw new Error("InvalidCharacterError: Failed to set a named property on 'DOMStringMap': '" + key + "' is not a valid attribute name.");
      }
      el.setAttribute(attr, String(value));
      return true;
    },
    deleteProperty(_t: any, key: string): any {
      const attr = datasetAttr(key);
      if (attr !== null) el.removeAttribute(attr);
      return true;
    },
    has(_t: any, key: string): any {
      const attr = datasetAttr(key);
      return attr !== null && el.hasAttribute(attr);
    },
    ownKeys(): any {
      const out: string[] = [];
      for (const name of el.attrMap.keys()) {
        const key = datasetKey(name);
        if (key !== null) out.push(key);
      }
      return out;
    },
    getOwnPropertyDescriptor(_t: any, key: string): any {
      const attr = datasetAttr(key);
      if (attr === null) return undefined;
      const v = el.getAttribute(attr);
      return v === null ? undefined : { value: v, enumerable: true, configurable: true };
    },
  });
  DATASETS.set(el, view);
  return view;
}

// ---------------------------------------------------------------------------
// Node

/** A fragment that is text drawn in its own style. */
export const FRAG_TEXT = 0;

/** A fragment that is an inline box's edge: its left or right margin, border and padding. */
export const FRAG_EDGE = 1;

/**
 * The line a fragment is on when the line box took up no height (an inline box around nothing).
 * It is no painted line's index, so it can't be confused with one.
 */
export const EMPTY_LINE = -1;

/**
 * Does the box have a fragment on a real line? An inline box around nothing records one on no
 * line at all, for the DOM's rects: it drew no line box, so it is no content to lay out either.
 */
export function hasLineFragment(el: Node, from: number = 0): boolean {
  for (let i = from; i < el.fragLine.length; i++) {
    if (el.fragLine[i] !== EMPTY_LINE) return true;
  }
  return false;
}

/**
 * The argument append() and its fellows take: a node as it is, or text for anything else a
 * script passes. A browser's DOMString conversion turns null into "null" here, so the same
 * conversion applies.
 */
function asInsertable(n: Node | string | number | null | undefined): Node {
  if (n instanceof Node) return n;
  return new Text(String(n));
}

/**
 * The nodes an insertion's arguments name, moved into one fragment in argument order, as the
 * DOM's "convert nodes into a node" does. Moving them together keeps a sibling argument from
 * jumping ahead of the ones after it, which inserting them one by one would allow.
 */
/**
 * The DOM's pre-insertion checks for a list of arguments, run before anything moves: a call that
 * throws must leave the tree as it was, and converting the arguments into a fragment has already
 * moved them.
 */
function ensureInsertableAll(parent: Node, nodes: (Node | string | number | null | undefined)[]): void {
  for (const n of nodes) ensureInsertable(parent, asInsertable(n));
}

function nodesFragment(nodes: (Node | string | number | null | undefined)[]): DocumentFragment {
  const frag = new DocumentFragment();
  for (const n of nodes) frag.appendChild(asInsertable(n));
  return frag;
}

/** Gives a subtree to a document: adoptNode asks for it, and every descendant reports it. */
function adoptOwner(node: Node, doc: Document): void {
  node.owner = doc;
  for (const k of node.kids) adoptOwner(k, doc);
}

/**
 * A WebIDL unsigned long: the integer modulo 2^32, so -1 is 4294967295 and a negative offset in
 * range (`-0x100000000 + 2`) is 2, as a browser converts it.
 */
function toUnsignedLong(value: any): number {
  const n = Math.floor(Number(value));
  if (Number.isNaN(n)) return 0;
  const m = n % 4294967296;
  return m < 0 ? m + 4294967296 : m;
}

function offsetIndex(offset: any, length: number, method: string): number {
  const at = toUnsignedLong(offset);
  if (at > length) {
    throw new Error(`IndexSizeError: Failed to execute '${method}': the offset ${at} is larger than the node's length (${length}).`);
  }
  return at;
}

function hierarchyError(message: string): Error {
  return new Error("HierarchyRequestError: " + message);
}

/**
 * The node a DOM method's argument must be, as WebIDL converts an interface-typed argument: a
 * node passes, and anything else — no argument, a number, a plain object — is a TypeError. The
 * check lives here because a loose call (untyped JavaScript, a framework) has to reach the
 * method: scriptc's typed boundary would refuse it before the runtime could throw.
 */
export function requireNode(value: any, method: string): Node {
  if (value instanceof Node) return value;
  throw new TypeError("Failed to execute '" + method + "': parameter is not of type 'Node'.");
}

/** The element child of a document, when it has one. */
function documentElementChild(doc: Node): Element | null {
  for (const k of doc.kids) if (k.isElementNode && k.pseudoKind === P.PE_NONE) return k as Element;
  return null;
}

function documentTypeChild(doc: Node): DocumentType | null {
  for (const k of doc.kids) if (k.nodeType === 10) return k as DocumentType;
  return null;
}

/**
 * The DOM's pre-insertion checks: a node goes only where the tree can hold it, and a document
 * takes one element and one doctype. A script that breaks them gets the HierarchyRequestError a
 * browser throws.
 */
function ensureInsertable(parent: Node, node: Node, replacing: boolean = false): void {
  const t = node.nodeType;
  if (t !== 1 && t !== 3 && t !== 4 && t !== 7 && t !== 8 && t !== 10 && t !== 11) {
    throw hierarchyError("The node type " + t + " cannot be inserted into a tree.");
  }
  for (let p: Node | null = parent; p !== null; p = p.parentNode) {
    if (p === node) throw hierarchyError("The node is an ancestor of the parent it would go into.");
  }
  const parentIsDoc = parent.nodeType === 9;
  if (parent.nodeType === 3 || parent.nodeType === 4 || parent.nodeType === 7 || parent.nodeType === 8) {
    throw hierarchyError("A CharacterData node cannot have children.");
  }
  if (parentIsDoc) {
    if (t === 3 || t === 4) throw hierarchyError("Text cannot be a child of a document.");
    if (t === 1) {
      const el = documentElementChild(parent);
      if (!replacing && el !== null && el !== node) throw hierarchyError("A document holds one element.");
    }
    if (t === 10) {
      const dt = documentTypeChild(parent);
      if (!replacing && dt !== null && dt !== node) throw hierarchyError("A document holds one doctype.");
    }
    if (t === 11) {
      let elements = 0;
      for (const k of node.kids) if (k.isElementNode && k.pseudoKind === P.PE_NONE) elements++;
      if (elements > 1) throw hierarchyError("A document holds one element, and the fragment has more.");
      if (!replacing && elements === 1 && documentElementChild(parent) !== null) {
        throw hierarchyError("A document holds one element.");
      }
    }
  } else if (t === 10) {
    throw hierarchyError("A doctype can only be a child of a document.");
  }
}

/** Whether two nodes' children are equal in order, for isEqualNode(). */
function equalChildren(a: Node, b: Node): boolean {
  const ak = a.childNodes;
  const bk = b.childNodes;
  if (ak.length !== bk.length) return false;
  for (let i = 0; i < ak.length; i++) {
    if (!ak[i].isEqualNode(bk[i])) return false;
  }
  return true;
}

/** The prefix an element or its ancestors bind to a namespace, for lookupPrefix(). */
function locatePrefix(el: Element | null, namespace: string): string | null {
  for (let e = el; e !== null; e = e.parentElement) {
    if (e.namespaceURI === namespace && e.prefix !== null) return e.prefix;
    for (const name of e.attributeNames()) {
      if (!name.startsWith("xmlns:")) continue;
      if (e.getAttribute(name) === namespace) return name.slice(6);
    }
  }
  return null;
}

/** Moves `child` under `parent`, the insertion step every tree mutation shares. */
function adoptInto(parent: Node, child: Node): void {
  let a: Node | null = parent;
  while (a !== null) {
    if (a === child) throw new Error("HierarchyRequestError: cannot insert a node into itself");
    a = a.parentNode;
  }
  if (child.parentNode !== null) child.parentNode.removeChild(child);
  materializeText(parent);
  child.parentNode = parent;
  // A node inserted into another document is adopted by it, as the spec's insert step says.
  const doc = parent.nodeDocument;
  if (child.ownerDocument !== doc) adoptOwner(child, doc);
}

/** Appends a node whose insertion into `parent` has been checked. A fragment isn't inserted:
 *  its children are, in order, leaving it empty. */
function appendChecked(parent: Node, node: Node): void {
  if (node.nodeType === 11) {
    for (const k of node.kids.slice()) appendChecked(parent, k);
    return;
  }
  adoptInto(parent, node);
  parent.kids.push(node);
  noteChildList(parent, [node], [], node.previousSibling, null);
  // A <style> in what was added has a sheet to parse, and one added to a <style> is its text.
  refreshAdded(node);
  // What a detached tree holds has no box to style yet: the insertion that puts it in the
  // document styles the subtree then.
  if (!parent.isConnected) return;
  if (styleInsertedText(parent, node) || styleAppendedBox(parent, node)) return;
  noteStructureChange(parent);
  noteDetailsInserted(node);
  invalidateStyleOf(parent);
}

/**
 * Every node: an element, a text node, a comment or a fragment. A node also carries the box
 * state layout, style and paint use. Text, comments and fragments never cascade rules of their
 * own (a text run takes its parent's computed style), but they are boxes all the same.
 */
export class Node extends EventTarget {
  get [Symbol.toStringTag](): string { return "Node"; }
  /**
   * True for a <style> element the build compiled: its text is already in the page's compiled
   * rules, so the runtime must not parse it again as a runtime sheet. A script writing new text
   * clears it, and the sheet becomes a runtime one.
   */
  compiledSheet = false;
  /**
   * The compiled style sheet this <style> element put into the page (see NODE_SHEET), or -1.
   * A script disables the sheet by its rules standing down in the cascade (style.ts).
   */
  sheetIndex = -1;
  /** True while the node's first computed state is the one @starting-style describes. */
  starting = false;
  static readonly ELEMENT_NODE = 1;
  static readonly ATTRIBUTE_NODE = 2;
  static readonly TEXT_NODE = 3;
  static readonly CDATA_SECTION_NODE = 4;
  static readonly PROCESSING_INSTRUCTION_NODE = 7;
  static readonly COMMENT_NODE = 8;
  static readonly DOCUMENT_NODE = 9;
  static readonly DOCUMENT_TYPE_NODE = 10;
  static readonly DOCUMENT_FRAGMENT_NODE = 11;

  nodeType: number = 0;
  /**
   * Which node was made first. It orders two nodes that are in different trees, where the tree has
   * no order of its own: compareDocumentPosition() puts the one made first before the other, as
   * Chrome does.
   */
  readonly serial: number = 0;
  // The tag is the one the node was made with, except through an upgrade of a custom element,
  // which makes a new element of the class and then tells it which tag it stands for.
  // Defaulted, so the class's fields are set before initNode() gives them their real values.
  nodeName: string = "";
  tagName: string = "";
  localName: string = "";
  /**
   * The document that made this node, when it is not the page's document: a node from
   * createHTMLDocument(), or from a document createDocument() made for XML. Null means the
   * page's document, which ownerDocument falls back to.
   */
  owner: Document | null = null;
  parentNode: Node | null = null;
  /**
   * The tree's nodes in document order, generated boxes included. Layout, style and paint see
   * every box; the DOM accessors below hide the generated ones, which aren't part of the tree.
   */
  kids: Node[] = [];
  /** The slot the shadow tree this node was given to holds it in, or null. */
  get assignedSlot(): Element | null {
    const parent = this.parentNode;
    if (parent === null || this.pseudoKind !== 0) return null;
    const shadow = parent.shadowTree();
    if (shadow === null) return null;
    for (const node of slotsIn(shadow)) {
      if (!node.isElementNode || (node as Element).localName !== "slot") continue;
      for (const n of assignedOf(node as Element)) if (n === this) return node as Element;
    }
    return null;
  }

  /** The shadow tree this node hosts, open or closed, or null. */
  shadowTree(): ShadowRoot | null { return null; }
  /** The node whose box holds this one's, as layout walks it: a shadow root's is its host. */
  layoutParent(): Node | null {
    if (this.parentNode === null && this instanceof ShadowRoot) return this.host;
    return this.parentNode;
  }
  hasShadowTree(): boolean { return this.shadowTree() !== null; }
  isShadowRootNode(): boolean { return this instanceof ShadowRoot; }
  /**
   * The boxes this node's children stand for in the flattened tree: a shadow host's shadow
   * children with its slots filled, or its own children. Null until a style pass computes it.
   */
  flat: Node[] | null = null;
  /** The text node standing for an element's own text, made once so childNodes identity holds. */
  ownTextNode: Node | null = null;
  /** What a slot was last assigned, so a change fires its slotchange. */
  assignedSnapshot: Node[] | null = null;
  /** The manual-assignment slot that took this node, so a later assign() can take it back. */
  manualSlot: Element | null = null;

  // Text: an element either holds its own text or has children.
  ownText: string = "";
  /**
   * The text layout formats for a text node. It starts as the node's data, but a flex
   * container folds a run of adjacent text nodes into one item, and that moves the run's text
   * here without touching the DOM's own data. See mergeTextRuns() in style.ts.
   */
  layoutText = "";
  /**
   * The text this node lays out as a block of its own: a text node lays out its layout text (a
   * flex container may have folded sibling runs into it), and an element its own text (the
   * generated content of ::before and ::after).
   */
  get flowText(): string {
    return this.isTextNode ? this.layoutText : this.ownText;
  }
  /**
   * PE_NONE, or PE_BEFORE/PE_AFTER for a node standing in for generated content. A pseudo node
   * is a real child (so layout and paint handle it like any box) but not part of the DOM: it
   * carries no attributes and never shows up in sibling counts.
   */
  pseudoKind: number = P.PE_NONE;
  /** The pseudo children of a runtime-created element, made when a rule first generates them. */
  beforePseudo: Element | null = null;
  afterPseudo: Element | null = null;
  /** A list item's marker box, made the first time the element computes as a list item. */
  markerPseudo: Element | null = null;
  /** A text field's ::placeholder box: the style its placeholder text is drawn with. */
  placeholderPseudo: Element | null = null;
  /** A dialog's ::backdrop box, painted by the top layer under a modal dialog. */
  backdropPseudo: Element | null = null;
  /** Style carriers for ::first-line and ::first-letter, read while painting the first line. */
  firstLinePseudo: Element | null = null;
  firstLetterPseudo: Element | null = null;
  /** The floated box a ::first-letter rule lifts the letter into, when the rule floats it. */
  firstLetterFloat: Element | null = null;
  /** The ::first-line box whose font re-broke the first line, when its metrics differ. */
  firstLineStyle: Element | null = null;
  /** A style carrier for ::selection: the colours selected text inside this element paints in. */
  selectionPseudo: Element | null = null;
  /** Style carriers for ::highlight(name): the colours each named highlight paints this text in. */
  highlightPseudos: Element[] = [];
  /** A style carrier for ::target-text: the colours the text fragment's stretch paints in. */
  targetTextPseudo: Element | null = null;
  /**
   * The ::scroll-marker-group box of a scroll container, a sibling the style pass makes, and the
   * ::scroll-marker boxes it holds, one per child, in the children's order.
   */
  scrollMarkerGroup: Element | null = null;
  scrollMarkers: Element[] = [];
  /**
   * The element a generated box belongs to, when that isn't its parent: a ::scroll-marker lives in
   * its scroll container's marker group but is styled by the rule matching the child it marks.
   */
  pseudoOrigin: Element | null = null;
  /** For a ::highlight() carrier, the name its rule gave it; "" otherwise. */
  pseudoName = "";
  /**
   * For a ::placeholder box, which properties its own rules declared in the last style pass
   * (indexed by property id; see style.ts). The field needs to know whether the placeholder
   * style sets a colour of its own, or only inherits the field's.
   */
  declaredProps: Uint8Array | null = null;
  /** Every attribute name in the order it was first set, for the attributes list's order. */
  attrOrder: string[] = [];
  /** The element's attributes that carry a namespace, keyed namespace|localName. */
  nsAttrs: Map<string, Attr> | null = null;
  /** The ::marker rules a dynamic element's selector table matched, kept for its marker box. */
  markerRules: readonly number[] = [];
  /** Build-time resolved file for an <img src>; "" for a broken or missing image. */
  imagePath = "";
  /**
   * The signature of the font settings this node's text last took (its font-variant and
   * font-feature-settings masks, its variation list and its synthesis), and the host's run id
   * for them; see featureRun() in style.ts.
   */
  featSig = -1;
  featSrc = -1;
  featRun = 0;
  featLang = "";
  /** Whether featRun still answers for the node's computed font settings. The style pass, an
   *  inherited copy and an animated value drop it; featureRun() sets it again with the tables'
   *  version it registered against. */
  featValid = false;
  featTables = -1;
  featGen = -1;
  /** The language this node last resolved to, and the tree version it resolved against (see
   *  langOf); both are invalidated by an attribute or tree change. */
  langVer = -1;
  langVal = "";
  /** The nearest ancestor (or this node) that is a query container for each axis, as the style
   *  pass settled it: what containerBasis() measures without walking the tree. A node the pass
   *  has not reached yet has cqKnown false, and the walk still answers for it. */
  cqInline: Node | null = null;
  cqBlock: Node | null = null;
  cqKnown = false;
  /** The extra word and letter spacing each line of a justified block takes, by line index. */
  lineExtraWord: number[] = [];
  lineExtraLetter: number[] = [];
  /** The host bitmap an inline <svg> draws into (see runtime/svg.ts), and its device size. */
  svgCanvas = -1;
  svgPixelsW = 0;
  svgPixelsH = 0;
  /** The sheet behind a runtime <style>, made when its text is first parsed. */
  sheet: CSSStyleSheet | null = null;

  // Candidate rule ids in cascade order. Parsed elements get them from the build-time cascade;
  // elements created at runtime match the compiled selector table (see style.ts).
  rules: readonly number[] = [];
  dynamic = false;
  rulesStale = false;
  /** Whether the style pass has made the carriers for this element's pseudo rules (see style.ts). */
  carriersDone = false;
  sensitiveStates: number = 0;
  state = 0;
  /** The element's node id in the accessibility tree, given the first time a tree holds it; 0
   *  until then. It stays the same from one tree to the next. */
  axUid = 0;
  inlineDefault: boolean = false;
  /** This node's own style version, moved by every style pass it takes; a used value the pass
   *  can change is remembered against it. */
  styleGen = 0;
  /** The used display display() last answered for this box, and the version it answered for. */
  dispGen = -1;
  dispVal = 0;
  /** The letter and word spacing spacingPx() last worked out, and the generation they belong to. */
  spaceGen = -1;
  spaceLetter = 0;
  spaceWord = 0;
  /** The `hidden` attribute, which hides the box: removing a node from paint and layout. */
  hiddenFlag = false;
  // Inline style: the style="" attribute and el.style. Created on first use; a computed style
  // view (getComputedStyle) is a separate, read-only object.
  styleDecl: StyleDeclaration | null = null;
  computedDecl: StyleDeclaration | null = null;

  // Computed style: one value and unit per property. Typed stores: a read of a `number[]` goes
  // through scriptc's bounds-checked union read, which the style and paint passes pay for on
  // every property they touch.
  sv: Float64Array = new Float64Array(P.PROP_COUNT);
  su: Float64Array = new Float64Array(P.PROP_COUNT);
  /**
   * Whether the element's own cascade declared a text decoration: its lines, style, colour or
   * thickness. A decoration belongs to the element that declares it and is drawn over the text
   * of its in-flow descendants, so the painter asks this of each element it walks up through.
   */
  decorDeclared = false;
  /**
   * Whether the author's own declarations set a background or border on this element. The UA
   * keeps drawing a widget's box only until one of those properties is the author's to set, as
   * CSS's appearance-disabling properties say; a colour field's swatch asks this.
   */
  faceDeclared = false;
  /**
   * The font size the cascade (or the parent it inherits from) gave this element in the last
   * pass, when an animation or transition replaced it with the value it shows; -1 when nothing
   * moved it. A transition starts from this value, not from the size a running one shows.
   */
  cascadeFontSize = -1;
  /**
   * The element's computed custom properties (--x), inherited from its parent and overridden by
   * its own declarations. Null until the element is styled.
   */
  cprops: Map<string, string> | null = null;
  /**
   * The unresolved text of each colour property whose value names currentColor, so a child that
   * inherits it can resolve currentColor against its own colour rather than the parent's. Null
   * until a declaration names currentColor.
   */
  colorText: Map<number, string> | null = null;
  /**
   * The computed form of each colour property whose value is a modern colour function: what CSSOM
   * reads it back as (lab(50 40 -30), oklch(0.585 0.233 277.117), color(srgb 0.5 0 0.5)). Null
   * until one is declared.
   */
  colorForm: Map<number, string> | null = null;
  /**
   * The inherited properties this node's own cascade declared, as a bitset over PROP_COUNT: the
   * inherited-only fast path leaves a child's own value alone when its parent's inherited value
   * moved and the child declared that value itself (see the fast path in style.ts).
   */
  inhDeclared: Uint32Array | null = null;
  /**
   * The properties this node's own declarations are computed from — a value that follows its
   * parent (`inherit`) or names currentColor — as a bitset over PROP_COUNT. The fast path
   * recomputes the node itself when one of them moved in its parent.
   */
  inhDepends: Uint32Array | null = null;
  /**
   * The class tokens that changed on the element since its last style pass, and whether any other
   * attribute changed or its children moved. The style engine needs them to tell whether a
   * descendant's style can be left alone when the element is restyled (see invalidation.ts).
   */
  identClasses: string[] | null = null;
  identOther = false;
  identStructure = false;
  /** The element's state bits at its last style pass, so a restyle can tell what state moved. */
  styleState = 0;
  /**
   * The properties an !important declaration set on this style pass. An important declaration
   * beats a CSS animation (a transition still beats it), so the animation engine leaves these
   * alone; the style pass clears the list and fills it again.
   */
  impProps: number[] = [];

  // Layout output, border box relative to the parent's border box.
  x = 0;
  y = 0;
  w = 0;
  h = 0;
  /** A border-box size the user's resize drag gave the box, or -1 when they haven't resized it. */
  resizeW = -1;
  resizeH = -1;
  /** Relative-positioning shift, applied on top of the normal-flow position. */
  relX = 0;
  relY = 0;
  /**
   * Where an out-of-flow box would have been in normal flow, relative to its parent's border box
   * (the same frame as x/y). -1 means the layout didn't get there.
   */
  staticX = 0;
  staticY = 0;
  /** An out-of-flow box in a line: how far along the line's own direction it would have gone. */
  staticFlow = 0;
  staticValid = false;
  /**
   * The grid area an out-of-flow box was placed in, which is its containing block when the grid
   * is one (CSS Grid 9.2), in the grid's border box coordinates.
   */
  /** Multi-column layout: where the column rules sit in the content box, and their run's height. */
  colRulesX: number[] = [];
  /** The top of each row of columns, which each hold that row's share of the rules. */
  colRuleYs: number[] = [];
  colRulesH = 0;
  /**
   * A box whose content spans more than one column draws in each of them: one group of
   * [x, y, width, height, first, last] per column, from the box's own corner, where `first` and
   * `last` say whether the group holds the box's start and end edges. Empty for an unsplit box.
   */
  fragBoxes: number[] = [];
  /** The tracks a subgrid adopts from its parent in each axis, in px, and their gutters. */
  sgCols: number[] = [];
  /** The track sizes the last layout resolved, per axis: what an auto repeat printed back needs. */
  gridUsedCols: number[] = [];
  gridUsedRows: number[] = [];
  /** What a grid's items ask of each column, before the tracks resolve them, and its own gutter. */
  gridColMin: number[] = [];
  gridColMax: number[] = [];
  gridColAuto: number[] = [];
  gridColGapUsed = 0;
  sgRows: number[] = [];
  sgColGap = 0;
  sgRowGap = 0;
  sgColSet = false;
  sgRowSet = false;
  gridCbValid = false;
  gridCbX = 0;
  gridCbY = 0;
  gridCbW = 0;
  gridCbH = 0;
  /** Out of flow and inline-level before it was blockified: its static position is inline. */
  wasInline = false;
  /** Which of `lines` a forced break ended (1) rather than the wrap (0), for text-align-last. */
  lineForced: number[] = [];
  contentX = 0; // content box offset and width within the border box
  contentY = 0;
  contentW = 0;
  contentH = 0;
  /**
   * 1 when the box laid its content out along a vertical inline axis (writing-mode vertical-*):
   * its children's coordinates are then swapped and turned a quarter clockwise, and its own
   * inline size is its height. See layoutBox and paintBox.
   */
  vtext = 0;
  /**
   * 1 when the box itself sits in a turned frame — its parent laid it out along a vertical inline
   * axis, so its width and height are the frame's block and inline sizes and its padding, border
   * and margin sides swap and turn (see turned in layout/box-model.ts).
   */
  inVtext = 0;
  /** The inline size the content was laid out across, in the content's own axes. */
  inlineAvail = 0;
  /** Set while a vertical box's auto height is measured from its content, so it can't recurse. */
  measuringV = false;
  /**
   * The content-box size a container query last read from this element, per axis, or -1 when no
   * query read that axis in the last style pass. A layout that changes one of them means the
   * queries' answers are out of date, and style and layout run again (see containerStale).
   */
  qUsedW = -1;
  qUsedH = -1;
  /**
   * The counters in scope when this box's style was computed, innermost last per name, or null
   * when none are (see the counter pass in style.ts).
   */
  counterVals: Map<string, number[]> | null = null;
  /** The counter instances this box's declarations created; they live until its parent ends. */
  counterOwn: { name: string; value: number; reversed: boolean }[] | null = null;
  /** Caption space above and below a table's border box, inside the element's own box. */
  boxTop = 0;
  boxBottom = 0;
  /**
   * The used border widths (top, right, bottom, left) and colors when the collapsed border model
   * moves them off the computed values: a cell around a half-shared grid line, a table around the
   * outer half, a row or row group whose borders are merged. Empty when computed is used.
   */
  bw: number[] = [];
  bc: number[] = [];
  /** The used padding (top, right, bottom, left) when it differs from the computed value: a table
   * under border-collapse ignores its padding. Empty when computed is used. */
  bpad: number[] = [];
  /**
   * A collapsing table's grid lines, each a rectangle (x, y, width, height, color) relative to the
   * table's border box: the table paints them itself, above its cells, with the color each
   * segment of a line resolved to. Empty for every other box.
   */
  tborder: number[] = [];
  /**
   * The `<col>` and `<colgroup>` boxes whose backgrounds the table paints, groups first and then
   * the columns: those boxes paint nothing themselves, so the table paints them beneath its rows
   * and cells. Each part's box is in `bgbox` and its row bands in `bgseg`. Empty for every other
   * box.
   */
  tcols: Node[] = [];
  /** A vertical table's grid extent along its inline axis, which is what its height holds. */
  tableInlineExtent = 0;
  /**
   * The areas a table part's background shows in, each a rectangle (x, y, width, height) relative
   * to the part's own border box: rows, row groups, columns and column groups paint their
   * background only where the cells are, so the border spacing between them stays clear. Empty
   * when the background covers the whole box.
   */
  bgseg: number[] = [];
  /**
   * The box a column or column group's background is sized and positioned in, (x, y, width,
   * height) relative to the table's border box. Empty for every other box.
   */
  bgbox: number[] = [];
  /**
   * True when the table layout put a cell in this row. A row whose cells are anonymous has no
   * table-cell children to find, so its background would otherwise paint nothing.
   */
  bgCells = false;
  /**
   * True when a cell sits only in collapsed rows or columns: it takes no room and paints nothing,
   * with its content, as a browser clips it away.
   */
  collapsedTrack = false;
  /** The share of a table's own height that its collapsed rows took, which the table loses. */
  collapsedRowH = 0;
  /** Height of the content plus padding, which can exceed the box (see scrollHeight). */
  naturalH = 0;
  /** Width of the content plus padding and the reach of out-of-flow boxes (see scrollWidth). */
  naturalW = 0;
  /**
   * Set while the box's own intrinsic width is being measured, so that a min-width or max-width
   * keyword met during that measurement doesn't measure it again and spin.
   */
  measuringW = false;
  /** The same for an intrinsic height, which is measured by laying the box out. */
  measuringH = false;
  // Collapsed margins escaping this box's top and bottom edges, as a positive and a negative
  // part (a collapsed margin is the largest positive plus the most negative). See layout.ts.
  escTopP = 0;
  escTopN = 0;
  escBotP = 0;
  escBotN = 0;
  /** True when the box has no height and its own margins collapse through it. */
  collapsesThrough = false;
  /**
   * The node's dirty bits (STYLE_*, LAYOUT_*, PAINT_* in invalidation.ts). A new node's own layout
   * is out of date until it is first laid out.
   */
  dirtyBits = LAYOUT_SELF;
  /**
   * What incremental layout knows about the box's last layouts (see layout/incremental.ts): up
   * to LAYOUT_SLOTS sets of the arguments a layout was called with, when it was made, and the
   * box's own outputs it left, newest first. The first is the layout the subtree holds now; the
   * others keep only the outputs, since a flex or grid container measures an item with other
   * arguments before it lays it out.
   */
  lSlots: number[] = [];
  lN = 0;
  /** The slot whose outputs the box shows while its subtree holds the first one's, or -1. */
  lPending = -1;
  /** The last pass in which a layout asked for that pass was dropped for room, or -1. */
  lLostPass = -1;
  /** A signature of what the style pass last gave layout to work from (see layout/incremental.ts). */
  lStyleA = 0;
  lStyleB = 0;
  lOwnText = "";
  lLayoutText = "";
  lKids = 0;
  /** The part of the layout signature the box's parent reads, and a positioned box's insets. */
  lParentFacing = 0;
  lInsets = 0;
  /** Whether the box is in incremental layout's set of positioned boxes, or of scroll containers. */
  lInOof = false;
  lInScrollers = false;
  /** The batch of box changes (boxChanges in invalidation.ts) this box was last queued in. */
  lKindStamp = 0;
  lPlaceStamp = 0;
  /** Whether the box is in the list of containers a query read a size from (queriedContainers). */
  qListed = false;
  /** The full style pass that last counted this box among those using an unsupported layout. */
  lUnsupportedPass = -1;
  /** Which build of incremental layout's box lists last reached this box (see layout/box.ts). */
  lStamp = -1;
  /**
   * Set when the box's own layout inputs changed since its last layout — its computed values or
   * an attribute — rather than only what it holds. A box whose own inputs are the same can be laid
   * out again on its own, with the arguments it was last given (see layout/incremental.ts).
   */
  lOwnChanged = true;
  /**
   * The intrinsic sizes measured for this box: `szN` entries of SZ_STRIDE numbers each in `szK`
   * (kind and flags, three sizes, the result), valid while `szEpoch` is the current one. Marking
   * the box or a descendant dirty empties it.
   */
  szK: number[] = [];
  szN = 0;
  szEpoch = -1;
  /** The entries a dirty mark set aside, so a relayout root can tell whether its answers moved. */
  szOld: number[] = [];
  szOldN = 0;
  szOldEpoch = -1;
  /**
   * How far the box's content is scrolled, in px: a scroll container's scrollTop/scrollLeft, and
   * an input's text inside the field (see paintInput). Clamped once the layout settles.
   */
  scrollY = 0;
  /** Whether layout has placed this scroller at its start edge, which is its right in RTL. */
  scrollStarted = false;
  /** The same, for the vertical axis: an RTL vertical box starts at the bottom. */
  scrollStartedY = false;
  scrollX = 0;
  /**
   * The snap areas this scroll container is snapped to, one per axis: a relayout keeps the scroll
   * on them, and an area that moves takes the scroll along. Set by the snap engine in the layout.
   */
  snapAreaX: Element | null = null;
  snapAreaY: Element | null = null;
  /**
   * True for a `position: fixed` box whose containing block is the viewport: no ancestor's
   * scrolling moves it, so its viewport position is the plain sum of its ancestors' offsets.
   * Set by the out-of-flow placement and cleared on every layout.
   */
  fixedViewport = false;
  /** When this element last scrolled (ms), for showing the overlay scrollbar. */
  lastScroll = -1e9;
  lines: string[] = [];
  lineWidths: number[] = [];
  /** The first line's `text-indent`, which shifts it and narrows it in the content box. */
  textIndent = 0;

  // Inline formatting output (for a block container with inline content): fragments, all
  // relative to this element's border box. See layoutInline in layout.ts.
  fragKind: number[] = [];
  fragStyle: Node[] = []; // element whose computed style draws the fragment
  fragOwner: Node[] = []; // element that receives events for the fragment
  fragText: string[] = [];
  fragX: number[] = [];
  fragTop: number[] = [];
  fragW: number[] = [];
  fragLine: number[] = [];
  lineBaseline: number[] = [];
  /** The block-axis middle of each line box: a line running down the page is aligned on its
   *  middle rather than on a font baseline, and this is where that middle is. */
  lineCentral: number[] = [];

  clearFragments(): void {
    // Most boxes hold no inline content, and an empty list needs no new one.
    if (this.fragKind.length > 0) this.fragKind = [];
    if (this.fragStyle.length > 0) this.fragStyle = [];
    if (this.fragOwner.length > 0) this.fragOwner = [];
    if (this.fragText.length > 0) this.fragText = [];
    if (this.fragX.length > 0) this.fragX = [];
    if (this.fragTop.length > 0) this.fragTop = [];
    if (this.fragW.length > 0) this.fragW = [];
    if (this.fragLine.length > 0) this.fragLine = [];
    if (this.lineBaseline.length > 0) this.lineBaseline = [];
    if (this.lineCentral.length > 0) this.lineCentral = [];
  }

  constructor(tag: string, text: string, rules: readonly number[], states: number, inline: boolean) {
    super();
    this.serial = ++nodeSerial;
    this.initNode(tag, text, rules, states, inline);
  }

  /**
   * Sets what a node is made of: the tag it stands for (or the #name of a node kind), the text it
   * holds, and the rules and state the build gave it. The constructor calls it, and so does the
   * step that gives an element its tag after a class's own constructor has run.
   */
  protected initNode(tag: string, text: string, rules: readonly number[], states: number, inline: boolean): void {    this.localName = tag;
    if (tag === "#text") {
      this.nodeType = 3;
      this.nodeName = "#text";
      this.tagName = "#text";
    } else if (tag === "#comment") {
      this.nodeType = 8;
      this.nodeName = "#comment";
      this.tagName = "#comment";
    } else if (tag === "#document-fragment") {
      this.nodeType = 11;
      this.nodeName = "#document-fragment";
      this.tagName = "#document-fragment";
    } else if (tag === "#doctype") {
      this.nodeType = 10;
      this.nodeName = "#doctype";
      this.tagName = "#doctype";
    } else if (tag === "#document") {
      this.nodeType = 9;
      this.nodeName = "#document";
      this.tagName = "#document";
    } else if (tag === "#cdata-section") {
      this.nodeType = 4;
      this.nodeName = "#cdata-section";
      this.tagName = "#cdata-section";
    } else if (tag === "#processing-instruction") {
      this.nodeType = 7;
      this.nodeName = "#processing-instruction";
      this.tagName = "#processing-instruction";
    } else {
      this.nodeType = 1;
      this.nodeName = tag.toUpperCase();
      this.tagName = tag.toUpperCase();
    }
    this.pseudoKind = tag === P.PSEUDO_TAGS[P.PE_BEFORE] ? P.PE_BEFORE
      : tag === P.PSEUDO_TAGS[P.PE_AFTER] ? P.PE_AFTER
      : tag === P.PSEUDO_TAGS[P.PE_MARKER] ? P.PE_MARKER
      : tag === P.PSEUDO_TAGS[P.PE_PLACEHOLDER] ? P.PE_PLACEHOLDER
      : tag === P.PSEUDO_TAGS[P.PE_BACKDROP] ? P.PE_BACKDROP
      : tag === P.PSEUDO_TAGS[P.PE_FIRST_LINE] ? P.PE_FIRST_LINE
      : tag === P.PSEUDO_TAGS[P.PE_FIRST_LETTER] ? P.PE_FIRST_LETTER
      : tag === P.PSEUDO_TAGS[P.PE_SELECTION] ? P.PE_SELECTION
      : tag === P.PSEUDO_TAGS[P.PE_HIGHLIGHT] ? P.PE_HIGHLIGHT
      : tag === P.PSEUDO_TAGS[P.PE_TARGET_TEXT] ? P.PE_TARGET_TEXT
      : tag === P.PSEUDO_TAGS[P.PE_SCROLL_MARKER] ? P.PE_SCROLL_MARKER
      : tag === P.PSEUDO_TAGS[P.PE_SCROLL_MARKER_GROUP] ? P.PE_SCROLL_MARKER_GROUP : P.PE_NONE;
    this.ownText = text;
    this.rules = rules;
    this.sensitiveStates = states;
    this.inlineDefault = inline;
  }

  /** A text node. */
  get isTextNode(): boolean {
    return this.nodeType === 3;
  }
  /** An element (1), as opposed to a text node, comment or fragment. */
  get isElementNode(): boolean {
    return this.nodeType === 1;
  }
  /** The parent, when it is an element (a text node's parentElement is null for a fragment). */
  get parentElement(): Element | null {
    const p = this.parentNode;
    return p instanceof Element ? p : null;
  }
  /**
   * The document a node belongs to. A browser answers null for a document's own ownerDocument; this
   * returns the document itself there, so the type can be non-null, which is what a script walking
   * from a node to its document wants: scriptc can't override an accessor with a narrower type
   * (issue 49), so the widening is done once here. scripts/tests check the null case where it
   * matters.
   */
  get ownerDocument(): Document {
    return this.owner !== null ? this.owner : document;
  }
  /**
   * The document a child inserted into this node belongs to. It is this node's own document,
   * except for a document itself, which is its own node document (and whose ownerDocument
   * getter falls back to the page's document instead).
   */
  get nodeDocument(): Document {
    return this.ownerDocument;
  }
  get nodeValue(): string | null {
    // A text, comment, CDATA section or processing instruction's value is its data.
    const t = this.nodeType;
    return t === 3 || t === 4 || t === 7 || t === 8 ? this.ownText : null;
  }
  set nodeValue(value: string | null) {
    const t = this.nodeType;
    if (t === 3 || t === 4 || t === 7 || t === 8) this.setText(value === null ? "" : value);
  }

  /**
   * An element whose content is one run of text keeps it as its own text until the DOM is looked at
   * through its children. This gives it the #text child a browser has, which is what firstChild,
   * childNodes, the sibling walks, a TreeWalker and a Range all see; the box now holds a child, so
   * styles are due again. The generated boxes a style made (a ::before, a ::selection carrier) are
   * not content of the element's own: they don't stop the text from becoming a child.
   */
  private observeText(): void {
    if (!hasRealChild(this) && this.ownText !== "" && this.nodeType === 1) {
      materializeText(this);
      const t = this.ownTextNode;
      // The run that became a child takes its style here, against this element, when nothing a
      // selector can see has moved; the frame then only lays the page out again.
      if (!this.isConnected) return;
      if (t !== null && !isTablePart(this) && !textDataMovesStyle(this)) {
        t.layoutText = t.ownText;
        computeStyles(t, this);
        invalidateLayout(this);
        return;
      }
      invalidateStyle();
    }
  }

  /** The node's children: every node in the tree, in document order. */
  get childNodes(): Node[] {
    this.observeText();
    const out: Node[] = [];
    for (const c of this.kids) if (c.pseudoKind === P.PE_NONE) out.push(c);
    const own = ownTextChild(this);
    if (own !== null) out.push(own);
    return out;
  }
  /** The node's element children, as a browser's `children` gives. */
  get children(): Element[] {
    const out: Element[] = [];
    for (const c of this.kids) if (c.isElementNode && c.pseudoKind === P.PE_NONE) out.push(c as Element);
    return out;
  }
  /** Whether the node has any children at all. */
  hasChildNodes(): boolean {
    for (const c of this.kids) if (c.pseudoKind === P.PE_NONE) return true;
    return ownTextChild(this) !== null;
  }
  get firstChild(): Node | null {
    this.observeText();
    for (const c of this.kids) if (c.pseudoKind === P.PE_NONE) return c;
    return ownTextChild(this);
  }
  get lastChild(): Node | null {
    this.observeText();
    for (let i = this.kids.length - 1; i >= 0; i--) if (this.kids[i].pseudoKind === P.PE_NONE) return this.kids[i];
    return ownTextChild(this);
  }
  get nextSibling(): Node | null {
    const p = this.parentNode;
    if (p === null) return null;
    p.observeText();
    for (let i = p.kids.indexOf(this) + 1; i < p.kids.length; i++) {
      if (p.kids[i].pseudoKind === P.PE_NONE) return p.kids[i];
    }
    return null;
  }
  get previousSibling(): Node | null {
    const p = this.parentNode;
    if (p === null) return null;
    p.observeText();
    for (let i = p.kids.indexOf(this) - 1; i >= 0; i--) {
      if (p.kids[i].pseudoKind === P.PE_NONE) return p.kids[i];
    }
    return null;
  }

  // scriptc gives a getter/setter pair one type, so the pair is any: a renderer's null or number
  // is converted, as a browser's DOMString conversion does.
  get textContent(): any {
    if (this instanceof HTMLTemplateElement) return this.content.textContent;
    if (this.nodeType === 3 || this.nodeType === 8) return this.ownText;
    if (this.kids.length === 0) return this.ownText;
    let s = "";
    // Generated content and comments aren't part of the DOM's text.
    for (const c of this.kids) if (c.pseudoKind === P.PE_NONE && c.nodeType !== 8) s += c.textContent;
    // An element whose only children are style carriers still holds its text as its own.
    return s === "" ? this.ownText : s;
  }
  set textContent(value: any) {
    if (this.nodeType === 3 || this.nodeType === 8) {
      this.setText(value);
      return;
    }
    // As in a browser, ::before and ::after survive: they're generated from style, not content.
    const pseudo: Node[] = [];
    const removed: Node[] = [];
    for (const c of this.kids) {
      if (c.pseudoKind === P.PE_NONE) {
        c.parentNode = null;
        removed.push(c);
      } else {
        pseudo.push(c);
      }
    }
    // The new text is a text node, as it is in a browser, even when the element had none.
    // A new node has no style yet, so the style work has to run again before layout reads it.
    this.kids = pseudo;
    this.ownText = "";
    let fresh: Text | null = null;
    if (value !== "") {
      const t = new Text(value);
      t.parentNode = this;
      // The text follows the marker and ::before, and comes before ::after.
      let at = 0;
      while (at < pseudo.length && (pseudo[at].pseudoKind === P.PE_MARKER || pseudo[at].pseudoKind === P.PE_BEFORE)) at++;
      this.kids.splice(at, 0, t);
      fresh = t;
      noteChildList(this, [t], removed);
    } else if (removed.length > 0) {
      noteChildList(this, [], removed);
    }
    // A <style>'s text is its sheet's source.
    refreshSheet(this);
    if (!this.isConnected) return;
    let textOnly = true;
    for (const c of removed) if (!c.isTextNode) { textOnly = false; break; }
    // Only text changed, which no selector can see (a text run is no child to :has() or :nth-*):
    // the new run takes its style against this element here, and the frame lays out and paints.
    if (!textOnly || textDataMovesStyle(this)) {
      noteStructureChange(this);
      invalidateStyleOf(this);
      return;
    }
    if (fresh !== null) {
      fresh.layoutText = fresh.ownText;
      if (!dirty.style) computeStyles(fresh, this);
    }
    invalidateLayout(this);
  }

  /**
   * The text as it is rendered: display: none skipped, block boundaries as line breaks, <br> as
   * a break, table rows and cells as newlines and tabs, and the white-space and text-transform
   * the computed style applies. A layout read, so pending style and layout are flushed first;
   * an SVG element has no innerText here, as the tests have it.
   */
  // One type for the getter/setter pair (scriptc refuses a pair that differs): text in, text out.
  get innerText(): any {
    if (this.nodeType === 3 || this.nodeType === 8) return this.ownText;
    if (this.isElementNode) {
      if (elementNamespace(this) !== "http://www.w3.org/1999/xhtml") return "";
      flushLayoutHook();
      return trimRendered(renderedText(this, previousRenderedChar(this))).split("\u0001").join(" ").split("\u0002").join("\t");
    }
    let s = "";
    for (const c of this.kids) {
      if (c.pseudoKind !== P.PE_NONE || c.nodeType === 8) continue;
      if (c instanceof Element && c.localName === "br") s += "\n";
      else s += c.textContent;
    }
    return s === "" ? this.ownText : s;
  }
  /** Writing it makes the text the content, a line break becoming a <br> (unless the white-space
   *  mode keeps the text as written). */
  set innerText(value: any) {
    const text = value === null || value === undefined ? "" : String(value);
    if (this.isElementNode && elementNamespace(this) === "http://www.w3.org/1999/xhtml") {
      const nodes = innerTextNodes(this, text);
      this.replaceChildren(...nodes);
      mergeTextBoundaries(this, nodes);
      return;
    }
    this.textContent = text;
  }

  get outerText(): any {
    return this.innerText;
  }
  set outerText(value: any) {
    const text = value === null || value === undefined ? "" : String(value);
    const parent = this.parentNode;
    if (this.isElementNode && parent !== null) {
      const nodes = innerTextNodes(this, text);
      this.replaceWith(...nodes);
      mergeTextBoundaries(parent, nodes);
      return;
    }
    this.textContent = text;
  }

  /** Replaces a text node's or comment's data. */
  protected setText(value: string): void {
    if (this.ownText === value) return;
    const old = this.ownText;
    this.ownText = value;
    noteCharacterData(this, old);
    // The text of a <style> is its sheet's source.
    refreshTextOwner(this);
    // A run's data can't change a selector's answer — except that a flex, grid or lanes container
    // decides a whitespace-only run's display from the text, and a drop cap lifts its letter out
    // of the run. Those still restyle the page; the others only need the new line breaking.
    const parent = this.parentNode;
    if (parent === null || !parent.isConnected) {
      // A run outside the document has no box: insertion styles it, and its data is what it lays
      // out then.
      this.layoutText = value;
      return;
    }
    if (!textDataMovesStyle(parent)) {
      this.layoutText = value;
      invalidateLayout(this);
      return;
    }
    noteStructureChange(parent);
    invalidateStyleOf(parent);
  }

  // --- Cloning -------------------------------------------------------------

  /**
   * A copy of the node. A deep copy carries the subtree's non-generated children; the ::before,
   * ::after and marker boxes come from style, so they are made again for the copy rather than
   * copied.
   */
  cloneNode(deep: boolean = false): Node {
    const copy = this.shallowClone();
    if (deep) {
      for (const c of this.kids) if (c.pseudoKind === P.PE_NONE) copy.appendChild(c.cloneNode(true));
      if (this.kids.length === 0 && this.ownText !== "") copy.ownText = this.ownText;
    }
    return copy;
  }

  /** A copy of just this node, without children. */
  protected shallowClone(): Node {
    let copy: Node;
    if (this.nodeType === 3) copy = new Text(this.ownText);
    else if (this.nodeType === 8) copy = new Comment(this.ownText);
    else if (this.nodeType === 11) copy = new DocumentFragment();
    else throw new Error("cloneNode() is not supported for this node");
    copy.owner = this.owner;
    return copy;
  }

  // --- Tree mutation -------------------------------------------------------

  appendChild<T extends Node>(child: any): T {
    const node = requireNode(child, "appendChild");
    ensureInsertable(this, node);
    // The work is a module function: this method is generic, so a call that reaches it through
    // an untyped receiver compiles its body against a dynamic `this`, where reading another
    // method of this class — a generic one especially — is not lowered.
    appendChecked(this, node);
    return child;
  }
  append(...nodes: (Node | string | number | null | undefined)[]): void {
    if (nodes.length === 0) return;
    ensureInsertableAll(this, nodes);
    const fragment = nodesFragment(nodes);
    ensureInsertable(this, fragment);
    appendChecked(this, fragment);
  }
  prepend(...nodes: (Node | string | number | null | undefined)[]): void {
    if (nodes.length === 0) return;
    ensureInsertableAll(this, nodes);
    this.insertBefore(nodesFragment(nodes), this.firstChild);
  }
  /** Puts nodes before this one among its parent's children; a detached node does nothing. */
  before(...nodes: (Node | string | number | null | undefined)[]): void {
    const parent = this.parentNode;
    if (parent === null) return;
    ensureInsertableAll(parent, nodes);
    // The reference is worked out after the arguments have moved: when they include this node,
    // it has left the parent by then, and the insertion goes before whatever now comes first.
    const prev = this.nonMovingPreviousSibling(nodes);
    const frag = nodesFragment(nodes);
    parent.insertBefore(frag, prev === null ? parent.firstChild : prev.nextSibling);
  }
  /** Puts nodes after this one among its parent's children; a detached node does nothing. */
  after(...nodes: (Node | string | number | null | undefined)[]): void {
    const parent = this.parentNode;
    if (parent === null) return;
    ensureInsertableAll(parent, nodes);
    const ref = this.viableSibling(nodes, true);
    parent.insertBefore(nodesFragment(nodes), ref);
  }

  /**
   * The child an insertion before or after this node should go in front of, when the arguments
   * may include this node (or the sibling that would be the reference) themselves: the DOM's
   * "viable previous/next sibling" steps, which keep the rest of the list in place.
   */
  private viableSibling(nodes: (Node | string | number | null | undefined)[], after: boolean): Node | null {
    const moving = (n: Node): boolean => nodes.indexOf(n) >= 0;
    if (after) {
      let next = this.nextSibling;
      while (next !== null && moving(next)) next = next.nextSibling;
      return next;
    }
    return this.nonMovingPreviousSibling(nodes);
  }

  /** The nearest preceding sibling that the call's arguments don't move, or null. */
  private nonMovingPreviousSibling(nodes: (Node | string | number | null | undefined)[]): Node | null {
    let prev = this.previousSibling;
    while (prev !== null && nodes.indexOf(prev) >= 0) prev = prev.previousSibling;
    return prev;
  }
  /**
   * Moves a node to a place among this node's children, keeping the node itself (state included),
   * as the move-before steps of DOM say; a plain insert of a connected node would leave state
   * behind.
   */
  moveBefore(node?: any, child?: any): Node {
    const n = requireNode(node, "moveBefore");
    if (child === undefined) {
      throw new TypeError("Failed to execute 'moveBefore': 2 arguments required, but only 1 present.");
    }
    if (n.parentNode === this) {
      // Already here: move within the child list.
      this.insertBefore(n, child);
      return n;
    }
    if (n.parentNode !== null) n.parentNode.removeChild(n);
    this.insertBefore(n, child);
    return n;
  }

  insertBefore(child: any, ref?: any): Node {
    const node = requireNode(child, "insertBefore");
    if (ref === null) {
      // Appending through the generic appendChild would read a member of this class through a
      // dynamic `this`, which a call from an untyped receiver compiles against.
      ensureInsertable(this, node);
      appendChecked(this, node);
      return node;
    }
    if (ref === undefined) {
      throw new TypeError("Failed to execute 'insertBefore': 2 arguments required, but only 1 present.");
    }
    const before = requireNode(ref, "insertBefore");
    if (before.parentNode !== this) throw new Error("NotFoundError: reference node is not a child");
    if (node === before) return node;
    ensureInsertable(this, node);
    if (node.nodeType === 11) {
      for (const k of node.kids.slice()) this.insertBefore(k, before);
      return node;
    }
    adoptInto(this, node);
    this.kids.splice(this.kids.indexOf(before), 0, node);
    noteChildList(this, [node], [], node.previousSibling, before);
    refreshAdded(node);
    if (!this.isConnected) return node;
    if (styleInsertedText(this, node)) return node;
    noteStructureChange(this);
    invalidateStyleOf(this);
    return node;
  }
  removeChild(child?: any): Node {
    const node = requireNode(child, "removeChild");
    const i = this.kids.indexOf(node);
    child = node;
    if (i < 0) throw new Error("NotFoundError: not a child of this node");
    const prev = child.previousSibling;
    const next = child.nextSibling;
    // Asked before the node leaves, since a custom element reports itself disconnected only when
    // it was connected.
    const wasConnected = child.isConnected;
    this.kids.splice(i, 1);
    child.parentNode = null;
    // Live ranges see the removal as the spec's remove steps say: one whose boundary was inside
    // the subtree moves to where the subtree was, and one after it in the parent shifts down.
    liveRangesSawRemoval(this, child, i);
    // A scroll container's marker group sits beside it, so it leaves with it.
    if (child instanceof HTMLElement && child.scrollMarkerGroup !== null) {
      const at = this.kids.indexOf(child.scrollMarkerGroup);
      if (at >= 0) this.kids.splice(at, 1);
      child.scrollMarkerGroup.parentNode = null;
      child.scrollMarkerGroup = null;
      child.scrollMarkers = [];
    }
    noteChildList(this, [], [child], prev, next);
    // A popover that leaves the document closes, going away from the screen it was on.
    if (wasConnected && openPopoverCount > 0) hidePopoversIn(child);
    if (wasConnected && CUSTOM_DEFS > 0) disconnectedSubtree(child);
    // A transition doesn't survive the element leaving the document: it is canceled there.
    if (wasConnected) cancelTransitionOnDetach(child);
    noteStructureChange(this);
    invalidateStyleOf(this);
    return child;
  }
  replaceChild(next?: any, old?: any): Node {
    const replacement = requireNode(next, "replaceChild");
    if (old === undefined) {
      throw new TypeError("Failed to execute 'replaceChild': 2 arguments required, but only 1 present.");
    }
    const child = requireNode(old, "replaceChild");
    if (child.parentNode !== this) throw new Error("NotFoundError: not a child of this node");
    if (replacement === child) return child;
    this.insertBefore(replacement, child);
    this.removeChild(child);
    return child;
  }
  remove(): void {
    if (this.parentNode !== null) this.parentNode.removeChild(this);
  }
  /**
   * Merges every run of adjacent text nodes below this node into one, and drops the empty ones,
   * as a browser's normalize() does. A live range's boundaries move with the text they point at.
   */
  normalize(): void {
    const walk = (parent: Node): void => {
      for (let k = 0; k < parent.kids.length;) {
        const child = parent.kids[k];
        if (!child.isTextNode) {
          walk(child);
          k++;
          continue;
        }
        const text = child as Text;
        if (text.ownText.length === 0) {
          parent.removeChild(text);
          continue;
        }
        const prev = k > 0 ? parent.kids[k - 1] : null;
        if (prev === null || !prev.isTextNode) {
          k++;
          continue;
        }
        const before = prev as Text;
        const at = before.ownText.length;
        before.appendData(text.ownText);
        // A boundary in the text that was merged in moves into the node it merged into, and one
        // in the parent at the join (between two text nodes of the run) is that same place.
        let r: Range | null = liveRangeHead;
        while (r !== null) {
          if (r.startContainer === text) { r.startContainer = before; r.startOffset += at; }
          else if (r.startContainer === parent && r.startOffset === k) { r.startContainer = before; r.startOffset = at; }
          if (r.endContainer === text) { r.endContainer = before; r.endOffset += at; }
          else if (r.endContainer === parent && r.endOffset === k) { r.endContainer = before; r.endOffset = at; }
          r = r.nextLive;
        }
        parent.removeChild(text);
      }
    };
    walk(this);
  }
  replaceChildren(...nodes: (Node | string | number | null | undefined)[]): void {
    // Replace all checks its arguments against the document as it will be, after the old
    // children are gone, so the element and doctype being replaced don't count against them.
    if (this.nodeType === 9) {
      let elements = 0;
      let doctypes = 0;
      for (const n of nodes) {
        const child = asInsertable(n);
        ensureInsertable(this, child, true);
        if (child.nodeType === 1) elements++;
        else if (child.nodeType === 10) doctypes++;
      }
      if (elements > 1) throw hierarchyError("A document holds one element.");
      if (doctypes > 1) throw hierarchyError("A document holds one doctype.");
    } else ensureInsertableAll(this, nodes);
    // Generated boxes come from style, not content, so they survive like they do in a browser.
    const pseudo: Node[] = [];
    const removed: Node[] = [];
    const wasConnected = this.isConnected;
    for (const c of this.kids) {
      if (c.pseudoKind === P.PE_NONE) {
        c.parentNode = null;
        removed.push(c);
      } else {
        pseudo.push(c);
      }
    }
    this.kids = pseudo;
    this.ownText = "";
    if (wasConnected && openPopoverCount > 0) for (const c of removed) hidePopoversIn(c);
    if (wasConnected && CUSTOM_DEFS > 0) for (const c of removed) disconnectedSubtree(c);
    // One childList record carries both sides: replace all is a single mutation, as a browser
    // reports it (removedChildren and addedChildren together), so inserting the new nodes one by
    // one through appendChild would report one record per node instead.
    const added: Node[] = [];
    if (nodes.length > 0 && this.nodeType === 9) {
      // A fragment can't hold a doctype, so a document takes its new children one by one.
      for (const n of nodes) {
        const k = asInsertable(n);
        // A fragment yields its children; nothing else is a node a document can hold.
        const take = k.nodeType === 11 ? k.kids.slice() : [k];
        for (const c of take) {
          if (c.parentNode !== null) c.parentNode.removeChild(c);
          c.parentNode = this;
          this.kids.push(c);
          added.push(c);
          refreshAdded(c);
        }
      }
    } else if (nodes.length > 0) {
      const frag = nodesFragment(nodes);
      for (const k of frag.kids.slice()) {
        k.parentNode = this;
        this.kids.push(k);
        added.push(k);
        refreshAdded(k);
      }
    }
    if (added.length > 0 || removed.length > 0) noteChildList(this, added, removed);
    refreshSheet(this);
    if (added.length > 0 || removed.length > 0) noteStructureChange(this);
    if (this.isConnected) invalidateStyleOf(this);
  }
  replaceWith(...nodes: (Node | string | number | null | undefined)[]): void {
    const parent = this.parentNode;
    if (parent === null) return;
    ensureInsertableAll(parent, nodes);
    // The nodes that follow this one, past any that are the arguments themselves: they stay
    // where they are when this node leaves and the arguments take its place.
    const next = this.viableSibling(nodes, true);
    const frag = nodesFragment(nodes);
    // The arguments may include this node itself, which has left the parent by now; the DOM's
    // replace-with steps still replace it in the parent when it is there, and pre-insert the
    // new nodes before the viable next sibling otherwise.
    if (this.parentNode === parent) parent.replaceChild(frag, this);
    else parent.insertBefore(frag, next);
  }
  /**
   * Whether two nodes are equal by the DOM's isEqualNode(): the same kind and name, the same
   * namespace, the same attributes with the same values, and (with their own trees) equal
   * children in the same order.
   */
  isEqualNode(other: Node | null): boolean {
    if (other === null || other === undefined) return false;
    if (other === this) return true;
    if (other.nodeType !== this.nodeType) return false;
    switch (this.nodeType) {
      case 1: {
        const a = this as unknown as Element;
        const b = other as unknown as Element;
        if (a.namespaceURI !== b.namespaceURI || a.prefix !== b.prefix || a.localName !== b.localName) return false;
        const an = a.attributeNames();
        const bn = b.attributeNames();
        if (an.length !== bn.length) return false;
        for (const name of an) {
          if (b.getAttribute(name) !== a.getAttribute(name)) return false;
          const anAttr = a.getAttributeNode(name);
          const bnAttr = b.getAttributeNode(name);
          if (anAttr !== null && bnAttr !== null && anAttr.namespaceURI !== bnAttr.namespaceURI) return false;
        }
        return equalChildren(a, b);
      }
      case 3:
      case 4:
      case 8:
        return (this as unknown as Text).data === (other as unknown as Text).data;
      case 7: {
        const a = this as unknown as ProcessingInstruction;
        const b = other as unknown as ProcessingInstruction;
        return a.target === b.target && a.data === b.data;
      }
      case 10: {
        const a = this as unknown as DocumentType;
        const b = other as unknown as DocumentType;
        return a.name === b.name && a.publicId === b.publicId && a.systemId === b.systemId;
      }
      default:
        return equalChildren(this, other);
    }
  }

  /** The namespace URI a prefix maps to at this node, by the DOM's lookupNamespaceURI algorithm. */
  lookupNamespaceURI(prefix: string | null): string | null {
    const p = prefix === undefined || prefix === "" ? null : prefix;
    if (this.nodeType === 9) {
      const root = (this as unknown as Document).documentElement;
      return root === null ? null : root.lookupNamespaceURI(p);
    }
    if (this.nodeType !== 1) {
      const owner = this.parentElement;
      return owner === null ? null : owner.lookupNamespaceURI(p);
    }
    const el = this as unknown as Element;
    if (el.namespaceURI !== null && el.prefix === p) return el.namespaceURI;
    for (const name of el.attributeNames()) {
      if (name === "xmlns") {
        if (p === null) return el.getAttribute(name);
      } else if (name.startsWith("xmlns:") && name.slice(6) === p) {
        return el.getAttribute(name);
      }
    }
    const parent = el.parentElement;
    return parent === null ? null : parent.lookupNamespaceURI(p);
  }

  /** The prefix this node binds to a namespace, by the DOM's lookupPrefix algorithm. */
  lookupPrefix(namespace: string | null): string | null {
    if (namespace === null || namespace === undefined || namespace === "") return null;
    if (this.nodeType === 9) {
      const root = (this as unknown as Document).documentElement;
      return root === null ? null : root.lookupPrefix(namespace);
    }
    const el: Element | null = this.nodeType === 1 ? (this as unknown as Element) : this.parentElement;
    return el === null ? null : locatePrefix(el, namespace);
  }

  /** Whether a namespace is the default namespace at this node. */
  isDefaultNamespace(namespace: string | null): boolean {
    const ns = namespace === null || namespace === undefined || namespace === "" ? null : namespace;
    return this.lookupNamespaceURI(null) === ns;
  }

  contains(other?: any): boolean {
    if (other === null || other === undefined) return false;
    const node = requireNode(other, "contains");
    let e: Node | null = node;
    while (e !== null) {
      if (e === this) return true;
      e = e.parentNode;
    }
    return false;
  }

  /** Whether the node is in the document: its tree's root is the document. */
  get isConnected(): boolean {
    const root = this.getRootNode();
    if (root.nodeType === 9) return true;
    // A shadow tree is connected when the element that hosts it is.
    return root instanceof ShadowRoot && root.host.isConnected;
  }

  /**
   * The top of the node's tree: the document, the shadow root it is in, or the node itself when
   * the tree is detached. There is no shadow DOM yet, so a detached node is its own root.
   */
  getRootNode(options?: { composed?: boolean }): Node {
    let n: Node = this;
    for (;;) {
      while (n.parentNode !== null) n = n.parentNode;
      // `composed` climbs out of a shadow tree to the document its host is in.
      if (options !== undefined && options.composed === true && n.nodeType === 11 && (n as ShadowRoot).host !== undefined) {
        n = (n as ShadowRoot).host;
        continue;
      }
      return n;
    }
  }

  /**
   * Where `other` sits relative to this node, as the DOM's bitmask: DOCUMENT_POSITION_FOLLOWING
   * when `other` comes after this node in the tree, PRECEDING when it comes before, CONTAINED_BY
   * when it is inside this node, CONTAINS when this node is inside it, and DISCONNECTED (with
   * IMPLEMENTATION_SPECIFIC) when the two are in different trees. A script tests the bit it needs.
   */
  compareDocumentPosition(other: Node): number {
    if (other === this) return 0;
    if (this.getRootNode() !== other.getRootNode()) {
      // Two trees have no order between them, so the flags carry the one Chrome picks: the node
      // made first comes first.
      return 0x01 | 0x20 | (this.serial < other.serial ? 0x04 : 0x02);
    }
    if (this.contains(other)) return 0x10 | 0x04;
    if (other.contains(this)) return 0x08 | 0x02;
    // The two children under the nearest common ancestor decide the order, so the two chains meet
    // there, climbing from the tree's root rather than step by step from the two nodes.
    const mine: Node[] = [];
    for (let n: Node | null = this; n !== null; n = n.parentNode) mine.push(n);
    const theirs: Node[] = [];
    for (let n: Node | null = other; n !== null; n = n.parentNode) theirs.push(n);
    let i = mine.length - 1;
    let j = theirs.length - 1;
    while (i > 0 && j > 0 && mine[i] === theirs[j]) {
      i--;
      j--;
    }
    const parent = mine[i + 1];
    if (parent === undefined) return 0x01 | 0x20;
    return parent.kids.indexOf(mine[i]) < parent.kids.indexOf(theirs[j]) ? 0x04 : 0x02;
  }

  /** Sends the event through this node's tree, and says whether a listener cancelled it. */
  dispatchEvent(event: Event): boolean {
    return dispatch(event, this);
  }

  // --- Children, in element terms ------------------------------------------

  get firstElementChild(): Element | null {
    for (const c of this.kids) if (c.isElementNode && c.pseudoKind === P.PE_NONE) return c as Element;
    return null;
  }
  get lastElementChild(): Element | null {
    for (let i = this.kids.length - 1; i >= 0; i--) {
      const c = this.kids[i];
      if (c.isElementNode && c.pseudoKind === P.PE_NONE) return c as Element;
    }
    return null;
  }
  get childElementCount(): number {
    let n = 0;
    for (const c of this.kids) if (c.isElementNode && c.pseudoKind === P.PE_NONE) n++;
    return n;
  }
  get nextElementSibling(): Element | null {
    const p = this.parentNode;
    if (p === null) return null;
    for (let i = p.kids.indexOf(this) + 1; i < p.kids.length; i++) {
      const c = p.kids[i];
      if (c.isElementNode && c.pseudoKind === P.PE_NONE) return c as Element;
    }
    return null;
  }
  get previousElementSibling(): Element | null {
    const p = this.parentNode;
    if (p === null) return null;
    for (let i = p.kids.indexOf(this) - 1; i >= 0; i--) {
      const c = p.kids[i];
      if (c.isElementNode && c.pseudoKind === P.PE_NONE) return c as Element;
    }
    return null;
  }

  // --- Events --------------------------------------------------------------

  addEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K,
    listener: (event: GlobalEventHandlersEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    // A null listener is accepted and does nothing, as the DOM has it.
    if (listener === null) return;
    let list = this.listeners.get(type);
    if (list === undefined) {
      list = [];
      this.listeners.set(type, list);
    }
    // The same listener registered twice with the same capture flag is kept once.
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    for (const entry of list) {
      if (entry.capture === capture &&
        ((entry.fn !== null && entry.fn === listener) || (entry.object !== null && entry.object === listener))) return;
    }
    list.push(listenerEntry(listener, options));
  }
  removeEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K,
    listener: (event: GlobalEventHandlersEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    const list = this.listeners.get(type);
    if (list === undefined || listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    for (let i = 0; i < list.length; i++) {
      const entry = list[i];
      const same = entry.fn !== null ? entry.fn === listener : entry.object === listener;
      if (same && entry.capture === capture) {
        list.splice(i, 1);
        return;
      }
    }
  }

  // --- Event handler properties --------------------------------------------
  // Browsers expose one IDL attribute per event on every element, and a framework checks for
  // it (`"onclick" in el`) before registering its listener. Each one below registers a listener
  // when set, as the browser's does.

  /** Handlers assigned as properties, keyed by event type; they are in `listeners` too. */
  private propertyHandlers: Map<string, Listener> | null = null;

  private handlerFor(type: string): Listener | null {
    const map = this.propertyHandlers;
    if (map === null) return null;
    const fn = map.get(type);
    return fn === undefined ? null : fn;
  }

  private setHandler(type: string, fn: Listener | null): void {
    const old = this.handlerFor(type);
    if (old !== null) this.removeEventListener(type, old);
    if (fn === null) {
      if (this.propertyHandlers !== null) this.propertyHandlers.delete(type);
      return;
    }
    if (this.propertyHandlers === null) this.propertyHandlers = new Map();
    this.propertyHandlers.set(type, fn);
    this.addEventListener(type, fn);
  }

  /**
   * Sets the handler for `type` by its name rather than through one of the properties below:
   * what a compiled inline handler attribute does, for any event name, including ones with no
   * property. It is the `on<type>` property's handler afterwards, so clearing that property
   * detaches it.
   */
  setEventHandler(type: string, fn: Listener | null): void {
    this.setHandler(type, fn);
  }

  get onabort(): Listener | null { return this.handlerFor("abort"); }
  set onabort(fn: Listener | null) { this.setHandler("abort", fn); }

  get onanimationcancel(): Listener | null { return this.handlerFor("animationcancel"); }
  set onanimationcancel(fn: Listener | null) { this.setHandler("animationcancel", fn); }

  get onanimationend(): Listener | null { return this.handlerFor("animationend"); }
  set onanimationend(fn: Listener | null) { this.setHandler("animationend", fn); }

  get onanimationiteration(): Listener | null { return this.handlerFor("animationiteration"); }
  set onanimationiteration(fn: Listener | null) { this.setHandler("animationiteration", fn); }

  get onanimationstart(): Listener | null { return this.handlerFor("animationstart"); }
  set onanimationstart(fn: Listener | null) { this.setHandler("animationstart", fn); }

  get onauxclick(): Listener | null { return this.handlerFor("auxclick"); }
  set onauxclick(fn: Listener | null) { this.setHandler("auxclick", fn); }

  get onbeforeinput(): Listener | null { return this.handlerFor("beforeinput"); }
  set onbeforeinput(fn: Listener | null) { this.setHandler("beforeinput", fn); }

  get onbeforematch(): Listener | null { return this.handlerFor("beforematch"); }
  set onbeforematch(fn: Listener | null) { this.setHandler("beforematch", fn); }

  get onbeforetoggle(): Listener | null { return this.handlerFor("beforetoggle"); }
  set onbeforetoggle(fn: Listener | null) { this.setHandler("beforetoggle", fn); }

  get onblur(): Listener | null { return this.handlerFor("blur"); }
  set onblur(fn: Listener | null) { this.setHandler("blur", fn); }

  get oncancel(): Listener | null { return this.handlerFor("cancel"); }
  set oncancel(fn: Listener | null) { this.setHandler("cancel", fn); }

  get oncanplay(): Listener | null { return this.handlerFor("canplay"); }
  set oncanplay(fn: Listener | null) { this.setHandler("canplay", fn); }

  get oncanplaythrough(): Listener | null { return this.handlerFor("canplaythrough"); }
  set oncanplaythrough(fn: Listener | null) { this.setHandler("canplaythrough", fn); }

  get onchange(): Listener | null { return this.handlerFor("change"); }
  set onchange(fn: Listener | null) { this.setHandler("change", fn); }

  get onclick(): Listener | null { return this.handlerFor("click"); }
  set onclick(fn: Listener | null) { this.setHandler("click", fn); }

  get onclose(): Listener | null { return this.handlerFor("close"); }
  set onclose(fn: Listener | null) { this.setHandler("close", fn); }

  get oncontextlost(): Listener | null { return this.handlerFor("contextlost"); }
  set oncontextlost(fn: Listener | null) { this.setHandler("contextlost", fn); }

  get oncontextmenu(): Listener | null { return this.handlerFor("contextmenu"); }
  set oncontextmenu(fn: Listener | null) { this.setHandler("contextmenu", fn); }

  get oncontextrestored(): Listener | null { return this.handlerFor("contextrestored"); }
  set oncontextrestored(fn: Listener | null) { this.setHandler("contextrestored", fn); }

  get oncopy(): Listener | null { return this.handlerFor("copy"); }
  set oncopy(fn: Listener | null) { this.setHandler("copy", fn); }

  get oncuechange(): Listener | null { return this.handlerFor("cuechange"); }
  set oncuechange(fn: Listener | null) { this.setHandler("cuechange", fn); }

  get oncut(): Listener | null { return this.handlerFor("cut"); }
  set oncut(fn: Listener | null) { this.setHandler("cut", fn); }

  get ondblclick(): Listener | null { return this.handlerFor("dblclick"); }
  set ondblclick(fn: Listener | null) { this.setHandler("dblclick", fn); }

  get ondrag(): Listener | null { return this.handlerFor("drag"); }
  set ondrag(fn: Listener | null) { this.setHandler("drag", fn); }

  get ondragend(): Listener | null { return this.handlerFor("dragend"); }
  set ondragend(fn: Listener | null) { this.setHandler("dragend", fn); }

  get ondragenter(): Listener | null { return this.handlerFor("dragenter"); }
  set ondragenter(fn: Listener | null) { this.setHandler("dragenter", fn); }

  get ondragleave(): Listener | null { return this.handlerFor("dragleave"); }
  set ondragleave(fn: Listener | null) { this.setHandler("dragleave", fn); }

  get ondragover(): Listener | null { return this.handlerFor("dragover"); }
  set ondragover(fn: Listener | null) { this.setHandler("dragover", fn); }

  get ondragstart(): Listener | null { return this.handlerFor("dragstart"); }
  set ondragstart(fn: Listener | null) { this.setHandler("dragstart", fn); }

  get ondrop(): Listener | null { return this.handlerFor("drop"); }
  set ondrop(fn: Listener | null) { this.setHandler("drop", fn); }

  get ondurationchange(): Listener | null { return this.handlerFor("durationchange"); }
  set ondurationchange(fn: Listener | null) { this.setHandler("durationchange", fn); }

  get onemptied(): Listener | null { return this.handlerFor("emptied"); }
  set onemptied(fn: Listener | null) { this.setHandler("emptied", fn); }

  get onended(): Listener | null { return this.handlerFor("ended"); }
  set onended(fn: Listener | null) { this.setHandler("ended", fn); }

  get onerror(): Listener | null { return this.handlerFor("error"); }
  set onerror(fn: Listener | null) { this.setHandler("error", fn); }

  get onfocus(): Listener | null { return this.handlerFor("focus"); }
  set onfocus(fn: Listener | null) { this.setHandler("focus", fn); }

  get onfocusin(): Listener | null { return this.handlerFor("focusin"); }
  set onfocusin(fn: Listener | null) { this.setHandler("focusin", fn); }

  get onfocusout(): Listener | null { return this.handlerFor("focusout"); }
  set onfocusout(fn: Listener | null) { this.setHandler("focusout", fn); }

  get onformdata(): Listener | null { return this.handlerFor("formdata"); }
  set onformdata(fn: Listener | null) { this.setHandler("formdata", fn); }

  get onfullscreenchange(): Listener | null { return this.handlerFor("fullscreenchange"); }
  set onfullscreenchange(fn: Listener | null) { this.setHandler("fullscreenchange", fn); }

  get onfullscreenerror(): Listener | null { return this.handlerFor("fullscreenerror"); }
  set onfullscreenerror(fn: Listener | null) { this.setHandler("fullscreenerror", fn); }

  get ongotpointercapture(): Listener | null { return this.handlerFor("gotpointercapture"); }
  set ongotpointercapture(fn: Listener | null) { this.setHandler("gotpointercapture", fn); }

  get oninput(): Listener | null { return this.handlerFor("input"); }
  set oninput(fn: Listener | null) { this.setHandler("input", fn); }

  get oninvalid(): Listener | null { return this.handlerFor("invalid"); }
  set oninvalid(fn: Listener | null) { this.setHandler("invalid", fn); }

  get onkeydown(): Listener | null { return this.handlerFor("keydown"); }
  set onkeydown(fn: Listener | null) { this.setHandler("keydown", fn); }

  get onkeypress(): Listener | null { return this.handlerFor("keypress"); }
  set onkeypress(fn: Listener | null) { this.setHandler("keypress", fn); }

  get onkeyup(): Listener | null { return this.handlerFor("keyup"); }
  set onkeyup(fn: Listener | null) { this.setHandler("keyup", fn); }

  get onload(): Listener | null { return this.handlerFor("load"); }
  set onload(fn: Listener | null) { this.setHandler("load", fn); }

  get onloadeddata(): Listener | null { return this.handlerFor("loadeddata"); }
  set onloadeddata(fn: Listener | null) { this.setHandler("loadeddata", fn); }

  get onloadedmetadata(): Listener | null { return this.handlerFor("loadedmetadata"); }
  set onloadedmetadata(fn: Listener | null) { this.setHandler("loadedmetadata", fn); }

  get onloadstart(): Listener | null { return this.handlerFor("loadstart"); }
  set onloadstart(fn: Listener | null) { this.setHandler("loadstart", fn); }

  get onlostpointercapture(): Listener | null { return this.handlerFor("lostpointercapture"); }
  set onlostpointercapture(fn: Listener | null) { this.setHandler("lostpointercapture", fn); }

  get onmousedown(): Listener | null { return this.handlerFor("mousedown"); }
  set onmousedown(fn: Listener | null) { this.setHandler("mousedown", fn); }

  get onmouseenter(): Listener | null { return this.handlerFor("mouseenter"); }
  set onmouseenter(fn: Listener | null) { this.setHandler("mouseenter", fn); }

  get onmouseleave(): Listener | null { return this.handlerFor("mouseleave"); }
  set onmouseleave(fn: Listener | null) { this.setHandler("mouseleave", fn); }

  get onmousemove(): Listener | null { return this.handlerFor("mousemove"); }
  set onmousemove(fn: Listener | null) { this.setHandler("mousemove", fn); }

  get onmouseout(): Listener | null { return this.handlerFor("mouseout"); }
  set onmouseout(fn: Listener | null) { this.setHandler("mouseout", fn); }

  get onmouseover(): Listener | null { return this.handlerFor("mouseover"); }
  set onmouseover(fn: Listener | null) { this.setHandler("mouseover", fn); }

  get onmouseup(): Listener | null { return this.handlerFor("mouseup"); }
  set onmouseup(fn: Listener | null) { this.setHandler("mouseup", fn); }

  get onpaste(): Listener | null { return this.handlerFor("paste"); }
  set onpaste(fn: Listener | null) { this.setHandler("paste", fn); }

  get onpause(): Listener | null { return this.handlerFor("pause"); }
  set onpause(fn: Listener | null) { this.setHandler("pause", fn); }

  get onplay(): Listener | null { return this.handlerFor("play"); }
  set onplay(fn: Listener | null) { this.setHandler("play", fn); }

  get onplaying(): Listener | null { return this.handlerFor("playing"); }
  set onplaying(fn: Listener | null) { this.setHandler("playing", fn); }

  get onpointercancel(): Listener | null { return this.handlerFor("pointercancel"); }
  set onpointercancel(fn: Listener | null) { this.setHandler("pointercancel", fn); }

  get onpointerdown(): Listener | null { return this.handlerFor("pointerdown"); }
  set onpointerdown(fn: Listener | null) { this.setHandler("pointerdown", fn); }

  get onpointerenter(): Listener | null { return this.handlerFor("pointerenter"); }
  set onpointerenter(fn: Listener | null) { this.setHandler("pointerenter", fn); }

  get onpointerleave(): Listener | null { return this.handlerFor("pointerleave"); }
  set onpointerleave(fn: Listener | null) { this.setHandler("pointerleave", fn); }

  get onpointermove(): Listener | null { return this.handlerFor("pointermove"); }
  set onpointermove(fn: Listener | null) { this.setHandler("pointermove", fn); }

  get onpointerout(): Listener | null { return this.handlerFor("pointerout"); }
  set onpointerout(fn: Listener | null) { this.setHandler("pointerout", fn); }

  get onpointerover(): Listener | null { return this.handlerFor("pointerover"); }
  set onpointerover(fn: Listener | null) { this.setHandler("pointerover", fn); }

  get onpointerup(): Listener | null { return this.handlerFor("pointerup"); }
  set onpointerup(fn: Listener | null) { this.setHandler("pointerup", fn); }

  get onprogress(): Listener | null { return this.handlerFor("progress"); }
  set onprogress(fn: Listener | null) { this.setHandler("progress", fn); }

  get onratechange(): Listener | null { return this.handlerFor("ratechange"); }
  set onratechange(fn: Listener | null) { this.setHandler("ratechange", fn); }

  get onreset(): Listener | null { return this.handlerFor("reset"); }
  set onreset(fn: Listener | null) { this.setHandler("reset", fn); }

  get onresize(): Listener | null { return this.handlerFor("resize"); }
  set onresize(fn: Listener | null) { this.setHandler("resize", fn); }

  get onscroll(): Listener | null { return this.handlerFor("scroll"); }
  set onscroll(fn: Listener | null) { this.setHandler("scroll", fn); }

  get onscrollend(): Listener | null { return this.handlerFor("scrollend"); }
  set onscrollend(fn: Listener | null) { this.setHandler("scrollend", fn); }

  get onsecuritypolicyviolation(): Listener | null { return this.handlerFor("securitypolicyviolation"); }
  set onsecuritypolicyviolation(fn: Listener | null) { this.setHandler("securitypolicyviolation", fn); }

  get onseeked(): Listener | null { return this.handlerFor("seeked"); }
  set onseeked(fn: Listener | null) { this.setHandler("seeked", fn); }

  get onseeking(): Listener | null { return this.handlerFor("seeking"); }
  set onseeking(fn: Listener | null) { this.setHandler("seeking", fn); }

  get onselect(): Listener | null { return this.handlerFor("select"); }
  set onselect(fn: Listener | null) { this.setHandler("select", fn); }

  get onselectionchange(): Listener | null { return this.handlerFor("selectionchange"); }
  set onselectionchange(fn: Listener | null) { this.setHandler("selectionchange", fn); }

  get onselectstart(): Listener | null { return this.handlerFor("selectstart"); }
  set onselectstart(fn: Listener | null) { this.setHandler("selectstart", fn); }

  get onslotchange(): Listener | null { return this.handlerFor("slotchange"); }
  set onslotchange(fn: Listener | null) { this.setHandler("slotchange", fn); }

  get onstalled(): Listener | null { return this.handlerFor("stalled"); }
  set onstalled(fn: Listener | null) { this.setHandler("stalled", fn); }

  get onsubmit(): Listener | null { return this.handlerFor("submit"); }
  set onsubmit(fn: Listener | null) { this.setHandler("submit", fn); }

  get onsuspend(): Listener | null { return this.handlerFor("suspend"); }
  set onsuspend(fn: Listener | null) { this.setHandler("suspend", fn); }

  get ontimeupdate(): Listener | null { return this.handlerFor("timeupdate"); }
  set ontimeupdate(fn: Listener | null) { this.setHandler("timeupdate", fn); }

  get ontoggle(): Listener | null { return this.handlerFor("toggle"); }
  set ontoggle(fn: Listener | null) { this.setHandler("toggle", fn); }

  get ontouchcancel(): Listener | null { return this.handlerFor("touchcancel"); }
  set ontouchcancel(fn: Listener | null) { this.setHandler("touchcancel", fn); }

  get ontouchend(): Listener | null { return this.handlerFor("touchend"); }
  set ontouchend(fn: Listener | null) { this.setHandler("touchend", fn); }

  get ontouchmove(): Listener | null { return this.handlerFor("touchmove"); }
  set ontouchmove(fn: Listener | null) { this.setHandler("touchmove", fn); }

  get ontouchstart(): Listener | null { return this.handlerFor("touchstart"); }
  set ontouchstart(fn: Listener | null) { this.setHandler("touchstart", fn); }

  get ontransitioncancel(): Listener | null { return this.handlerFor("transitioncancel"); }
  set ontransitioncancel(fn: Listener | null) { this.setHandler("transitioncancel", fn); }

  get ontransitionend(): Listener | null { return this.handlerFor("transitionend"); }
  set ontransitionend(fn: Listener | null) { this.setHandler("transitionend", fn); }

  get ontransitionrun(): Listener | null { return this.handlerFor("transitionrun"); }
  set ontransitionrun(fn: Listener | null) { this.setHandler("transitionrun", fn); }

  get ontransitionstart(): Listener | null { return this.handlerFor("transitionstart"); }
  set ontransitionstart(fn: Listener | null) { this.setHandler("transitionstart", fn); }

  get onvolumechange(): Listener | null { return this.handlerFor("volumechange"); }
  set onvolumechange(fn: Listener | null) { this.setHandler("volumechange", fn); }

  get onwaiting(): Listener | null { return this.handlerFor("waiting"); }
  set onwaiting(fn: Listener | null) { this.setHandler("waiting", fn); }

  get onwheel(): Listener | null { return this.handlerFor("wheel"); }
  set onwheel(fn: Listener | null) { this.setHandler("wheel", fn); }
}

/**
 * A list of nodes, as querySelectorAll() returns one. Here it is the array the runtime builds,
 * so indexing, length and the array methods all work.
 */
export type NodeList<T = Node> = readonly T[];
export type NodeListOf<T extends Node = Node> = readonly T[];

/**
 * The NodeList constructor, for the instanceof checks pages make. The lists this runtime hands
 * out are plain arrays (a querySelectorAll result is one), so none of them is a NodeList.
 */
class NodeListCtor {
}
export const NodeList: any = NodeListCtor;

/** Which of the getElements* queries a collection answers. */
const COLL_TAG = 0;
const COLL_CLASS = 1;
const COLL_NAME = 2;
// The document's own lists (forms, images, links, anchors, embeds/plugins, scripts, applets).
const COLL_FORM = 3;
const COLL_IMAGE = 4;
const COLL_LINK = 5;
const COLL_ANCHOR = 6;
const COLL_EMBED = 7;
const COLL_SCRIPT = 8;
const COLL_APPLET = 9;
// A table's own lists: its rows (in its sections), a section's rows, a row's cells, and a table's
// body sections. They collect by the relation to the collection's root, not by a query.
const COLL_TABLE_ROWS = 10;
const COLL_SECTION_ROWS = 11;
const COLL_ROW_CELLS = 12;
const COLL_TABLE_SECTIONS = 13;

const HTML_NS = "http://www.w3.org/1999/xhtml";

// The collections a script asked for, which every tree or class change brings up to date. They
// are a linked list through the collections themselves rather than an array: scriptc copies an
// Array subclass structurally when it crosses into dynamic code (scriptc issue 44), and an
// `any` field is such a crossing, while a field typed with the class keeps the reference.
let liveHead: HTMLCollection | null = null;

function refreshLiveCollections(): void {
  let c: HTMLCollection | null = liveHead;
  while (c !== null) {
    fillCollection(c);
    c = c.nextLive;
  }
}

/** Forgets the collections of the page that just ended (the WPT runner reuses the process). */
export function clearLiveCollections(): void {
  liveHead = null;
}

/**
 * A list of elements that stays live: a getElementsByTagName/ClassName/Name result re-reads the
 * tree whenever a node comes or goes, or an element's class, id or name changes, so the same
 * object always answers for the page as it is now.
 *
 * The elements are the collection's own array slots, so positional reads (`list[0]`) and
 * `length` come from the array itself and the refresh rebuilds it in place. An array rather than
 * a dictionary of index properties: scriptc refuses a program's class-to-primitive conversions
 * (reading a node as text) as soon as any class instance takes a property by a computed name, so
 * the indices are storage and not dynamic keys. `item()` and `namedItem()` complete the API.
 */
export class HTMLCollection extends Array<Element> {
  get [Symbol.toStringTag](): string { return "HTMLCollection"; }
  readonly root: Node;
  readonly kind: number;
  readonly arg: string;
  /** The document's lists include the root element itself; an element's own exclude it. */
  readonly includeSelf: boolean;
  /** The next collection in the runtime's list of live ones; null at the end. */
  nextLive: HTMLCollection | null = null;

  constructor(root: Node, kind: number, arg: string, includeSelf: boolean = false) {
    super();
    this.root = root;
    this.kind = kind;
    this.arg = arg;
    this.includeSelf = includeSelf;
    // Filled and registered through free functions: under a dynamic compile an Array subclass
    // can reach its constructor with no methods on `this` (scriptc issue 44), so the constructor
    // asks for nothing of its own.
    fillCollection(this);
    this.nextLive = liveHead;
    liveHead = this;
  }

  /** Re-reads the tree. The runtime calls this after a tree or attribute change. */
  refresh(): void {
    fillCollection(this);
  }

  item(index: number): Element | null {
    return index >= 0 && index < this.length ? this[index] : null;
  }

  /** The first element whose id is `name`, or else the first whose name attribute is. */
  namedItem(name: string): Element | null {
    for (const e of this) if (e.id === name) return e;
    for (const e of this) if (e.getAttribute("name") === name) return e;
    return null;
  }
}

/** Rebuilds a live collection's contents in place from the tree it watches. */
function fillCollection(c: HTMLCollection): void {
  const out: Element[] = [];
  const root = c.root;
  if (c.includeSelf && root.isElementNode && root.pseudoKind === P.PE_NONE &&
    collectionMatches(root as Element, c.kind, c.arg, root)) out.push(root as Element);
  collectMatching(root, c.kind, c.arg, out, root);
  // Rebuilt in place: indices past the new length come off, so a shortened list can't hand out
  // a removed node.
  c.length = 0;
  for (const e of out) c.push(e);
}

/** The list a getElements* query answers with, named for the elements the query asked about. */
export type HTMLCollectionOf<T extends Element = Element> = HTMLCollection;

/** Whether `el` belongs in a collection of the given query. */
function collectionMatches(el: Element, kind: number, arg: string, root: Node): boolean {
  if (kind === COLL_TABLE_ROWS) {
    // A row belongs to a table when it is the table's child or a section's child, so a nested
    // table's rows, and a row in a wrapper element, stay out of the list.
    if (el.localName !== "tr" || el.namespaceURI !== HTML_NS) return false;
    const p = el.parentNode;
    if (p === root) return true;
    if (p === null || !p.isElementNode) return false;
    const parent = p as Element;
    const section = (parent.localName === "thead" || parent.localName === "tbody" || parent.localName === "tfoot") &&
      parent.namespaceURI === HTML_NS;
    return section && parent.parentNode === root;
  }
  if (kind === COLL_SECTION_ROWS) return el.localName === "tr" && el.namespaceURI === HTML_NS && el.parentNode === root;
  if (kind === COLL_ROW_CELLS) {
    return (el.localName === "td" || el.localName === "th") && el.namespaceURI === HTML_NS && el.parentNode === root;
  }
  if (kind === COLL_TABLE_SECTIONS) return el.localName === "tbody" && el.namespaceURI === HTML_NS && el.parentNode === root;
  if (kind === COLL_TAG) return arg === "*" || el.localName.toLowerCase() === arg;
  if (kind === COLL_FORM) return el.localName === "form";
  if (kind === COLL_IMAGE) return el.localName === "img";
  if (kind === COLL_LINK) return (el.localName === "a" || el.localName === "area") && el.getAttribute("href") !== null;
  if (kind === COLL_ANCHOR) return el.localName === "a" && el.getAttribute("name") !== null;
  if (kind === COLL_EMBED) return el.localName === "embed";
  if (kind === COLL_SCRIPT) return el.localName === "script";
  if (kind === COLL_APPLET) return el.localName === "applet";
  if (kind === COLL_CLASS) {
    // Every class in the list is required, however the argument space-separated them.
    for (const n of arg.split(" ")) if (n !== "" && !el.classList.contains(n)) return false;
    return true;
  }
  return el.getAttribute("name") === arg;
}

/** Adds every matching element under `node`, in document order. `root` stays the element the
 *  collection watches, which is what a table's own lists compare a row's parent against. */
function collectMatching(node: Node, kind: number, arg: string, out: Element[], root: Node): void {
  for (const c of node.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    const e = c as Element;
    if (collectionMatches(e, kind, arg, root)) out.push(e);
    collectMatching(e, kind, arg, out, root);
  }
}

/** What a node with children gives: the child elements and selection over the subtree. */
export interface ParentNode {
  readonly children: Element[];
  readonly childElementCount: number;
  readonly firstElementChild: Element | null;
  readonly lastElementChild: Element | null;
  querySelector<T extends Element = Element>(selector: string): T | null;
  querySelectorAll<T extends Element = Element>(selector: string): T[];
  append(...nodes: (Node | string)[]): void;
  prepend(...nodes: (Node | string)[]): void;
  replaceChildren(...nodes: (Node | string)[]): void;
}

// ---------------------------------------------------------------------------
// Element

/** Whether the page is visible to the user: an app's page always is, but a script may compare
 *  against either state, as it does with lib.dom's type. */
export type DocumentVisibilityState = "visible" | "hidden";

/** How a script's scroll gets where it is going: `instant` jumps there, `smooth` travels over
 *  frames, and `auto` follows the box's computed scroll-behavior. */
export type ScrollBehavior = "auto" | "instant" | "smooth";

/** The options `scroll()`, `scrollTo()` and `scrollBy()` take: an offset per axis, and how to
 *  get there (`auto` follows scroll-behavior, `instant` jumps, `smooth` travels). */
export type ScrollToOptions = { left?: number; top?: number; behavior?: ScrollBehavior };

/** The options `scrollIntoView()` takes: which edge of the scrollport to line up on each axis —
 *  `start`, `center`, `end` or `nearest` — and how to get there. */
export type ScrollIntoViewOptions = { behavior?: ScrollBehavior; block?: string; inline?: string };

/**
 * Brings the page's computed styles up to date, as a browser does for a DOM call that reads
 * them: a class set in the same task counts before the next frame.
 */
function flushStyleWork(el: Element): void {
  if (!dirty.style) return;
  let root: Node = el;
  while (root.parentElement !== null) root = root.parentElement;
  const page = root === document.documentElement;
  // The flag goes before the pass, so a pass that asks for another (a font-size transition that
  // just started measures the em lengths again) gets it now, before the read.
  if (page) dirty.style = false;
  computeStyles(root, null);
  if (page && dirty.style) {
    dirty.style = false;
    computeStyles(root, null);
  }
}

// ---------------------------------------------------------------------------
// Pointer capture
//
// The host presses one pointer at a time (the mouse), so one element at a time holds a capture.
// A captured pointer's events go to the element that took it, whatever is under the pointer,
// which is how a drag keeps working after it leaves the element it started on.

/** The pointer ids the host has pressed, which are the ones setPointerCapture() takes. */
const activePointers: number[] = [];
/** The element holding the capture, and the pointer it holds. */
let capturedElement: Element | null = null;
let capturedPointerId = -1;

/** Records a host press or release: a capture is only possible while the pointer is down. */
export function notePointerActive(id: number, active: boolean): void {
  const i = activePointers.indexOf(id);
  if (active === (i >= 0)) return;
  if (active) activePointers.push(id);
  else activePointers.splice(i, 1);
}

/** The element holding the pointer's capture, which takes the pointer's events until it lets go. */
export function pointerCaptureElement(): Element | null {
  return capturedElement;
}

/** Ends a capture the host takes away, as the button lifting does. */
export function endPointerCapture(id: number): void {
  if (capturedElement === null || capturedPointerId !== id) return;
  const el = capturedElement;
  capturedElement = null;
  capturedPointerId = -1;
  dispatch(trusted(new PointerEvent("lostpointercapture", { bubbles: true, composed: true })), el);
}

/** An element: the only nodes that carry attributes, a style object or a class list. */
/**
 * The engine's keyframe rows for an animation a script describes, each [name, offset, property,
 * value, unit, ...]. An array of frames keeps the offsets it gives (evenly spaced otherwise), and
 * one object maps properties to value lists laid out over evenly spaced offsets. `comp` is the
 * composite every frame's values carry, packed above their units.
 */
function rowsFromParts(made: { texts: string[]; offsets: number[]; comps: number[] }): number[][] {
  const frames: number[][] = [];
  for (let i = 0; i < made.texts.length; i++) {
    const row: number[] = [-1, made.offsets[i]];
    // A script's keyframe parses its values like an inline style, so shadow and filter lists
    // register their rows in the same tables.
    for (const d of parseDeclarationBlock(made.texts[i], getSheetFonts())) {
      for (const c of d.decls) {
        if (c.prop !== undefined) {
          // A CSS-wide keyword: the frame keeps the keyword and resolves it against the element
          // when the animation applies it, since `inherit` reaches for the parent's value.
          const ids = longhandIds(c.prop);
          if (ids === null) continue;
          const code = wideCode(c.value === undefined ? "" : c.value);
          for (const p of ids) row.push(p, code, packUnit(P.U_WIDE, made.comps[i]));
          continue;
        }
        row.push(c.p);
        row.push(c.v);
        row.push(packUnit(c.u, made.comps[i]));
      }
    }
    frames.push(row);
  }
  frames.sort((a, b) => a[1] - b[1]);
  return frames;
}

/** Whether a property may be animated on a pseudo-element's box. A first-letter, first-line or
 *  selection style takes the text properties and the box's colours; anything else (a transform, a
 *  margin) isn't its to move. A ::marker takes fewer still: its colour and text, not an opacity or
 *  a background (css-pseudo-4 §3.4). */
function pseudoAnimatable(p: number, marker: boolean): boolean {
  if (marker) return p !== P.P_OPACITY && p !== P.P_BACKGROUND_COLOR;
  return p === P.P_COLOR || p === P.P_BACKGROUND_COLOR || p === P.P_OPACITY ||
    p === P.P_LETTER_SPACING || p === P.P_WORD_SPACING || p === P.P_LINE_HEIGHT ||
    p === P.P_FONT_SIZE || p === P.P_FONT_WEIGHT || p === P.P_FONT_STYLE ||
    p === P.P_FONT_FAMILY || p === P.P_FONT_FAMILY_LIST || p === P.P_TEXT_TRANSFORM ||
    p === P.P_TEXT_SHADOW || p === P.P_TEXT_EMPHASIS_STYLE || p === P.P_TEXT_EMPHASIS_COLOR ||
    p === P.P_VISIBILITY;
}

/** A script's keyframes as the engine's rows and the declarations text an effect reads back. */
export function parseKeyframes(keyframes: any, comp: number = AC_REPLACE): { rows: number[][]; texts: string[] } {
  const made = keyframeParts(keyframes, comp);
  return { rows: rowsFromParts(made), texts: made.texts };
}

/** A script's keyframes: the declarations text, offset and composite of each, in order. */
function keyframeParts(keyframes: any, comp: number): { texts: string[]; offsets: number[]; comps: number[] } {
  const texts: string[] = [];
  const offsets: number[] = [];
  const comps: number[] = [];
  if (Array.isArray(keyframes)) {
    const list = keyframes as any[];
    for (let i = 0; i < list.length; i++) {
      const k = list[i];
      const at = typeof k.offset === "number" ? k.offset : list.length > 1 ? i / (list.length - 1) : 1;
      offsets.push(at);
      comps.push(typeof k.composite === "string" ? animComposite(k.composite) : comp);
      texts.push(frameText(k, ["offset", "easing", "composite"]));
    }
  } else if (keyframes !== null && typeof keyframes === "object") {
    // A keyframes object writes one value, or an array of values, per property; `composite`
    // and `easing` describe the frames rather than setting a property of their own.
    const names: string[] = [];
    for (const n of Object.keys(keyframes)) {
      if (n !== "composite" && n !== "easing") names.push(n);
    }
    const own = typeof keyframes.composite === "string" ? animComposite(keyframes.composite) : comp;
    let count = 1;
    for (const n of names) {
      const v = keyframes[n];
      if (Array.isArray(v) && v.length > count) count = v.length;
    }
    for (let i = 0; i < count; i++) {
      const parts: string[] = [];
      for (const n of names) {
        const v = keyframes[n];
        const one = Array.isArray(v) ? v[Math.min(i, v.length - 1)] : v;
        if (one === null || one === undefined) continue;
        parts.push(kebabName(n) + ": " + String(one));
      }
      offsets.push(count > 1 ? i / (count - 1) : 1);
      comps.push(own);
      texts.push(parts.join("; "));
    }
  }
  return { texts, offsets, comps };
}

/** A keyframe object's declarations as a style block, leaving the frame's own keys out. */
function frameText(k: any, skip: string[]): string {
  const parts: string[] = [];
  for (const n of Object.keys(k)) {
    if (skip.indexOf(n) >= 0) continue;
    const v = k[n];
    if (v === null || v === undefined) continue;
    parts.push(kebabName(n) + ": " + String(v));
  }
  return parts.join("; ");
}

/** A camelCase property as CSS writes it: backgroundColor is background-color. */
function kebabName(name: string): string {
  return name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
}

/** The direction an options object names, as the engine's AD_* value. */
function animDirection(v: any): number {
  if (v === "reverse") return P.AD_REVERSE;
  if (v === "alternate") return P.AD_ALTERNATE;
  if (v === "alternate-reverse") return P.AD_ALTERNATE_REVERSE;
  return P.AD_NORMAL;
}

/** The fill an options object names, as the engine's AF_* value. */
function animFill(v: any): number {
  if (v === "forwards") return P.AF_FORWARDS;
  if (v === "backwards") return P.AF_BACKWARDS;
  if (v === "both") return P.AF_BOTH;
  return P.AF_NONE;
}

/** The pseudo-element types Element.pseudo() knows; anything else is null, as the spec has it. */
const KNOWN_PSEUDO_TYPES = new Set([
  // Tree-abiding pseudo-elements have an interface of their own; ::first-line, ::first-letter
  // and ::selection don't, and pseudo() answers null for them.
  "::before", "::after", "::marker", "::placeholder", "::backdrop", "::scroll-marker",
  "::scroll-marker-group", "::view-transition", "::details-content", "::file-selector-button",
  "::cue", "::column",
]);

/**
 * The CSSPseudoElement interface: one object for each pseudo-element of an element, the same
 * object each time it is asked for. Its geometry comes from the generated box its type names
 * (a ::before or ::after box, a marker), not from the originating element's box.
 */
export class CSSPseudoElement {
  get [Symbol.toStringTag](): string { return "CSSPseudoElement"; }
  /** The pseudo-element's type, serialized in lowercase: "::before". */
  readonly type: string;
  /** The element the pseudo-elements hang off, however deep they nest. */
  readonly element: Element;
  /** The element, or the pseudo-element a nested one sits in. */
  readonly parent: any;
  private subs: Map<string, CSSPseudoElement> | null = null;

  constructor(type: string, element: Element, parent: any) {
    this.type = String(type).trim().toLowerCase();
    this.element = element;
    this.parent = parent;
  }

  /** The pseudo-element's selector: its own type, lowercase. */
  get selectorText(): string {
    return this.type;
  }

  /** A pseudo-element of a pseudo-element (a ::marker of a ::before), the same object each call. */
  pseudo(type: string): CSSPseudoElement | null {
    const t = String(type).trim().toLowerCase();
    if (!KNOWN_PSEUDO_TYPES.has(t)) return null;
    if (this.subs === null) this.subs = new Map();
    let sub = this.subs.get(t);
    if (sub === undefined) {
      sub = new CSSPseudoElement(t, this.element, this);
      this.subs.set(t, sub);
    }
    return sub;
  }

  /**
   * The generated box this pseudo-element's type names, if the page has one: a ::before or
   * ::after box, a marker, a dialog's ::backdrop, a field's ::placeholder. A pseudo-element of a
   * pseudo-element reads the box of the pseudo-element it sits in. Types with no box here give
   * null.
   */
  private box(): Element | null {
    const owner = this.parent instanceof CSSPseudoElement ? this.parent.box() : this.element;
    if (owner === null) return null;
    if (this.type === "::before") return owner.beforePseudo;
    if (this.type === "::after") return owner.afterPseudo;
    if (this.type === "::marker") return owner.markerPseudo;
    if (this.type === "::placeholder") return owner.placeholderPseudo;
    if (this.type === "::backdrop") return owner.backdropPseudo;
    return null;
  }

  /** The pseudo-element's border box, or an empty rect when its box isn't generated. */
  getBoundingClientRect(): DOMRect {
    flushLayoutHook();
    const b = this.box();
    return b === null || isUnrendered(b) ? new DOMRect(0, 0, 0, 0) : b.getBoundingClientRect();
  }
  getClientRects(): DOMRect[] {
    flushLayoutHook();
    const b = this.box();
    return b === null || isUnrendered(b) ? [] : b.getClientRects();
  }
  convertPointFromNode(point: any, _from: any, _options?: any): DOMPoint {
    return DOMPoint.fromPoint(point);
  }
  convertRectFromNode(rect: any, _from: any, _options?: any): DOMQuad {
    return DOMQuad.fromRect(rect);
  }
  convertQuadFromNode(quad: any, _from: any, _options?: any): DOMQuad {
    if (quad instanceof DOMQuad) return quad;
    return DOMQuad.fromRect(quad);
  }
  /**
   * The pseudo-element's quads: one for its box in the space `options.box` names ("content",
   * "padding", "border" or "margin"; the border box by default). A box that isn't generated has
   * none, as in a browser.
   */
  getBoxQuads(options?: any): DOMQuad[] {
    flushLayoutHook();
    const b = this.box();
    if (b === null || isUnrendered(b)) return [];
    const which = options !== undefined && options !== null && typeof options.box === "string"
      ? options.box : "border";
    const r = b.getBoundingClientRect();
    let left = r.left, top = r.top, right = r.right, bottom = r.bottom;
    const bt = b.usedBorder(0, P.P_BORDER_TOP_WIDTH), br = b.usedBorder(1, P.P_BORDER_RIGHT_WIDTH);
    const bb = b.usedBorder(2, P.P_BORDER_BOTTOM_WIDTH), bl = b.usedBorder(3, P.P_BORDER_LEFT_WIDTH);
    if (which === "padding" || which === "content") {
      left += bl;
      top += bt;
      right -= br;
      bottom -= bb;
    }
    if (which === "content") {
      left += b.sv[P.P_PADDING_LEFT];
      top += b.sv[P.P_PADDING_TOP];
      right -= b.sv[P.P_PADDING_RIGHT];
      bottom -= b.sv[P.P_PADDING_BOTTOM];
    }
    if (which === "margin") {
      left -= b.sv[P.P_MARGIN_LEFT];
      top -= b.sv[P.P_MARGIN_TOP];
      right += b.sv[P.P_MARGIN_RIGHT];
      bottom += b.sv[P.P_MARGIN_BOTTOM];
    }
    return [DOMQuad.fromRect(new DOMRect(left, top, right - left, bottom - top))];
  }
}

/** The composite an options object or a keyframe names, as the engine's AC_* value. */
function animComposite(v: any): number {
  if (v === "add") return AC_ADD;
  if (v === "accumulate") return AC_ACCUMULATE;
  return AC_REPLACE;
}

/** The element fullscreen was asked for, while the window is fullscreen; null otherwise. */
let fullscreenEl: Element | null = null;

/** The document's visibility: "hidden" while its window is minimized. */
let visibilityState: DocumentVisibilityState = "visible";

/**
 * The window was minimized or restored (EV_VISIBILITY): the document's visibility state follows,
 * and a change fires visibilitychange at the document.
 */
export function setDocumentVisibility(hidden: boolean): void {
  const state: DocumentVisibilityState = hidden ? "hidden" : "visible";
  if (visibilityState === state) return;
  visibilityState = state;
  const ev = trusted(new Event("visibilitychange"));
  ev.target = document;
  dispatch(ev, document);
}

/** Fires fullscreenchange at the document, as entering or leaving fullscreen does. */
function fireFullscreenChange(): void {
  const ev = trusted(new Event("fullscreenchange"));
  ev.target = document;
  dispatch(ev, document);
}

/** Leaves fullscreen, as Escape or the menu's role does; the window goes back to its frame. */
export function exitFullscreenDocument(): Promise<void> {
  if (fullscreenEl === null) return Promise.resolve();
  fullscreenEl = null;
  hostWindowFullscreen(0);
  fireFullscreenChange();
  return Promise.resolve();
}

/**
 * The host reports that the window entered or left fullscreen (EV_FULLSCREEN), which is how the
 * green button and the system's own shortcut arrive. A state the page already knows is no change.
 */
export function windowFullscreenChanged(): void {
  const on = hostWindowFullscreenState() !== 0;
  if (on === (fullscreenEl !== null)) return;
  fullscreenEl = on ? document.documentElement : null;
  fireFullscreenChange();
}

/** A class list bound to the element it belongs to. */
function makeClassList(el: Element): DOMTokenList {
  const list = new DOMTokenList();
  list.owner = el;
  return list;
}

export class Element extends Node {
  get [Symbol.toStringTag](): string { return "Element"; }
  namespaceURI: string | null = "http://www.w3.org/1999/xhtml";
  /** The namespace prefix the element was made with, or null when it has none. */
  prefix: string | null = null;
  protected idValue: string;
  readonly classList: DOMTokenList = makeClassList(this);

  /** The length of an SVG <path>'s outline in user units, as `getTotalLength()` reports it.
   *  Any other element has no path and answers 0. */
  getTotalLength(): number {
    return this.localName === "path" ? pathTotalLength(this.getAttribute("d") ?? "") : 0;
  }

  /** The point a distance along an SVG <path>'s outline, clamped to its ends, as
   *  `getPointAtLength()` reports it; another element answers the origin. */
  getPointAtLength(distance: number): DOMPoint {
    if (this.localName !== "path") return new DOMPoint(0, 0);
    const p = pathPointAtLength(this.getAttribute("d") ?? "", Number(distance));
    return new DOMPoint(p.x, p.y);
  }

  /** An element's listeners are typed by ElementEventMap, as the DOM lib types them. */
  addEventListener<K extends keyof ElementEventMap>(type: K,
    listener: (event: ElementEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    super.addEventListener(type, listener, options);
  }
  removeEventListener<K extends keyof ElementEventMap>(type: K,
    listener: (event: ElementEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    super.removeEventListener(type, listener, options);
  }
  /**
   * Makes the window fullscreen for this element: the window fills the screen, the page keeps its
   * layout, and `document.fullscreenElement` is this element until the page leaves fullscreen.
   */
  requestFullscreen(): Promise<void> {
    if (fullscreenEl === this) return Promise.resolve();
    fullscreenEl = this;
    hostWindowFullscreen(1);
    fireFullscreenChange();
    return Promise.resolve();
  }
  /**
   * The attributes other than id, class, style and hidden, which have slots of their own. This
   * is the storage; `attributes` is the Attr list a script reads.
   */
  readonly attrMap: Map<string, string> = new Map();
  /**
   * The class this element was made from, when it is a custom element, and which of the class's
   * callbacks it has. Null for an element of a built-in class, which is most of them.
   */
  hooks: CustomElementState | null = null;
  /**
   * The declarations the element's presentation attributes stand for, as the SVG painter's
   * hints (see runtime/hints.ts), and whether they need reading again. Changing any attribute
   * clears the cache, so the next style pass sees the new value: a presentation attribute is a
   * hint in the cascade, and setAttribute() on it restyles the element the way the same
   * declaration in a style="" attribute would.
   */
  hintDecls: Decl[] | null = null;
  hintStale = true;

  // The parameters are defaulted so that `new Class()` works for a class a script defines: its
  // constructor calls super() with nothing, and the registry gives the element its tag.
  constructor(tag: string = "", id: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super(tag, "", rules, states, inline);
    this.idValue = id;
  }

  /**
   * The live range over a form control's value that the Selection API's createValueRange()
   * makes. An element that holds no value text of its own (anything but an <input> or
   * <textarea>, or an input type the API doesn't cover) throws NotSupportedError.
   */
  createValueRange(start?: number, end?: number): OpaqueRange {
    return createValueRangeFor(this, start, end);
  }

  get id(): string {
    return this.idValue;
  }
  set id(value: string) {
    const old = this.idValue === "" ? null : this.idValue;
    this.idValue = value;
    if (value !== "") this.recordSlotAttribute("id");
    if (this.dynamic) this.rulesStale = true;
    noteAttribute(this, "id", old);
    invalidateStyle();
  }

  /**
   * The inline declarations, as a style object. What a script gets is the named-property view of
   * the declaration (see styleView), which also answers to a property name it computes.
   */
  get style(): CSSStyleDeclaration {
    if (this.styleDecl === null) this.styleDecl = new StyleDeclaration(this, false);
    return styleView(this.styleDecl);
  }

  /**
   * A script may assign a string to `style`, which CSSOM's `[PutForwards=cssText]` forwards to
   * the declaration's text: `el.style = "top: 50px"` replaces the inline declarations. Without
   * the setter the property is read-only and that assignment throws.
   */
  set style(value: string | null) {
    this.setStyleText(value === null || value === undefined ? "" : String(value));
  }

  /**
   * Sets the inline declarations from a style attribute's text without going through the
   * attribute: a style attribute, a clone and a mounted node all set the block this way.
   */
  setStyleText(text: string): void {
    if (this.styleDecl === null) this.styleDecl = new StyleDeclaration(this, false);
    this.styleDecl.setBlock(text);
  }

  /** The read-only view getComputedStyle() hands out, kept per element. */
  get computedStyle(): StyleDeclaration {
    if (this.computedDecl === null) this.computedDecl = new StyleDeclaration(this, true);
    return this.computedDecl;
  }

  /** The element's `data-*` attributes, as the camelCase properties a browser exposes. */
  get dataset(): any {
    return makeDataset(this);
  }

  /** The transitions and animations on it, or with `subtree` on its descendants too. */
  getAnimations(options: GetAnimationsOptions = {}): Animation[] {
    return elementAnimations(this, options.subtree === true);
  }

  /**
   * Starts an animation the script describes: keyframes as an array of property objects (each an
   * `offset` and declarations) or one object mapping properties to value lists, and timing as a
   * duration number or an options object. The animation runs on the frame clock and reads back
   * through its Animation, which `getAnimations()` reports too.
   */
  animate(keyframes: Keyframe[] | PropertyIndexedKeyframes, options: KeyframeAnimationOptions | number = {}): Animation {
    const timing: any = typeof options === "number" ? { duration: options } : options;
    const pseudo = typeof timing.pseudoElement === "string" ? timing.pseudoElement : "";
    // An animation with a pseudoElement option moves that pseudo-element's box, and only the
    // properties the pseudo-element accepts: a ::first-letter has no transform to move.
    const pseudoTarget = pseudo === "" ? null : this.pseudoBox(pseudo);
    const target: Element = pseudoTarget === null ? this : pseudoTarget;
    const markerTarget = pseudoTarget !== null && pseudoTarget.pseudoKind === P.PE_MARKER;
    // Options name the composite for every frame; a keyframe that names its own wins.
    const made = parseKeyframes(keyframes, animComposite(timing.composite));
    let frames = made.rows;
    if (pseudo !== "") {
      frames = frames.map((row) => {
        const kept: number[] = [row[0], row[1]];
        for (let k = 2; k + 2 < row.length; k += 3) {
          if (pseudoAnimatable(row[k], markerTarget)) kept.push(row[k], row[k + 1], row[k + 2]);
        }
        return kept;
      });
    }
    const effect = new KeyframeEffect(target, frames, made.texts);
    const run = new KeyframeRun();
    run.name = -1;
    run.blocks = frames;
    run.effect = effect;
    effect.run = run;
    const props: number[] = [];
    for (const row of frames) {
      for (let k = 2; k + 2 < row.length; k += 3) if (props.indexOf(row[k]) < 0) props.push(row[k]);
    }
    run.props = props;
    run.dur = typeof timing.duration === "number" ? timing.duration : 0;
    run.delay = typeof timing.delay === "number" ? timing.delay : 0;
    const iter = typeof timing.iterations === "number" ? timing.iterations : 1;
    run.iter = iter === Infinity ? -1 : iter;
    run.dir = animDirection(timing.direction);
    run.fill = animFill(timing.fill);
    run.play = P.APS_RUNNING;
    // Linear is animate()'s default, unlike a CSS animation's ease.
    const tf = timingRow(typeof timing.easing === "string" ? timing.easing : "linear");
    if (tf !== null) run.tfs = [tf];
    return startScriptRun(target, run);
  }

  /** A new element of the same kind, carrying this one's attributes and inline style. */
  protected makeClone(): Element {
    // A copy of a custom element is made by the class defined for its tag, as a browser has it.
    const custom = constructCustom(this.localName);
    if (custom !== null) {
      custom.copyIdFrom(this);
      return custom;
    }
    return newElementFor(this.localName, this.idValue, "", [], 0, this.inlineDefault);
  }

  /** Takes another element's id without reporting it: a copy of an element is made quietly. */
  copyIdFrom(other: Element): void {
    this.idValue = other.idValue;
  }

  protected shallowClone(): Node {
    const copy = this.makeClone();
    copy.namespaceURI = this.namespaceURI;
    copy.prefix = this.prefix;
    copy.owner = this.owner;
    // Copied without a report: a browser makes the copy's attributes silently too.
    copy.classList.setValue(this.classList.value);
    for (const name of this.attrOrder) copy.attrOrder.push(name);
    for (const [name, value] of this.attrMap) copy.attrMap.set(name, value);
    if (this.nsAttrs !== null) {
      copy.nsAttrs = new Map();
      for (const [key, attr] of this.nsAttrs) {
        copy.nsAttrs.set(key, new Attr(attr.name, attr.value, copy, attr.namespaceURI, attr.prefix, attr.localName));
      }
    }
    if (this.styleDecl !== null && this.styleDecl.present) copy.setStyleText(this.styleDecl.cssText);
    copy.hiddenFlag = this.hiddenFlag;
    copy.imagePath = this.imagePath;
    // A copy matches the selectors at its new place in the tree, like a node made at runtime.
    copy.dynamic = true;
    copy.rulesStale = true;
    return copy;
  }

  cloneNode(deep: boolean = false): Node {
    const copy = super.cloneNode(deep) as Element;
    if (deep) this.cloneClonableShadowInto(copy);
    return copy;
  }

  /**
   * Gives `copy` a copy of this element's clonable shadow tree, as a clone brings it along. A
   * tree that isn't clonable is the host's alone, as a browser's cloneNode() leaves it.
   */
  cloneClonableShadowInto(copy: Element): void {
    const shadow = this.shadowRootEl;
    if (shadow === null || !shadow.clonable) return;
    const root = copy.attachShadow({ mode: shadow.mode, delegatesFocus: shadow.delegatesFocus, slotAssignment: shadow.slotAssignment, clonable: true, serializable: shadow.serializable });
    for (const c of shadow.kids) if (c.pseudoKind === P.PE_NONE) root.appendChild(c.cloneNode(true));
  }

  get className(): any {
    return this.classList.value;
  }
  set className(value: any) {
    const old = this.classList.value === "" ? null : this.classList.value;
    if (value !== null && value !== undefined && String(value) !== "") this.noteAttrOrder("class");
    this.classList.setValue(value);
    noteAttribute(this, "class", old);
  }

  /** The list the aria-actions getter reflects, and the attribute value it came from. */
  private actionsBase: Element[] | null = null;
  private actionsBaseAttr: string | null = null;
  /** The connected targets last handed out, so repeated reads give the same array. */
  private actionsVisible: Element[] | null = null;
  /** Whether the list came from the setter, which survives the attribute being removed. */
  private actionsSet = false;

  /**
   * The elements the aria-actions attribute names, as the ARIA actions API reflects them: null
   * when the attribute is absent and no setter gave a list, the elements the id references
   * resolve to otherwise, and only the ones still in the document. A value the setter stored
   * comes back as the same array until it is set again, as a FrozenArray does.
   */
  get ariaActionsElements(): Element[] | null {
    const raw = this.getAttribute("aria-actions");
    if (raw === null && !this.actionsSet) return null;
    if (this.actionsSet && raw !== null && this.actionsBase !== null && this.actionsBaseAttr === raw) {
      // The setter's own list, unchanged.
    } else if (raw !== null && (this.actionsBaseAttr !== raw || !this.actionsSet)) {
      const base: Element[] = [];
      const root = this.getRootNode();
      for (const id of raw.split(/\s+/)) {
        if (id === "") continue;
        const found = root.nodeType === 9
          ? (root as Document).getElementById(id)
          : this.ownerDocument.getElementById(id);
        if (found !== null && base.indexOf(found) < 0) base.push(found);
      }
      this.actionsBase = base;
      this.actionsBaseAttr = raw;
      this.actionsVisible = null;
    }
    const base = this.actionsBase;
    if (base === null) return null;
    const visible: Element[] = [];
    for (const el of base) if (el.isConnected) visible.push(el);
    if (this.actionsVisible !== null && this.actionsVisible.length === visible.length) {
      let same = true;
      for (let i = 0; i < visible.length; i++) {
        if (this.actionsVisible[i] !== visible[i]) { same = false; break; }
      }
      if (same) return this.actionsVisible;
    }
    this.actionsVisible = visible;
    return visible;
  }
  set ariaActionsElements(value: any) {
    if (value === null || value === undefined) {
      this.removeAttribute("aria-actions");
      this.actionsBase = null;
      this.actionsBaseAttr = null;
      this.actionsVisible = null;
      this.actionsSet = false;
      return;
    }
    if (!Array.isArray(value)) {
      throw new TypeError("Failed to set the 'ariaActionsElements' property on 'Element': The provided value is not a sequence.");
    }
    const list: Element[] = [];
    for (const v of value) {
      if (!(v instanceof Element)) {
        throw new TypeError("Failed to set the 'ariaActionsElements' property on 'Element': every value must be an Element.");
      }
      list.push(v);
    }
    // The attribute is only the presence flag: the setter does not write the ids.
    this.setAttribute("aria-actions", "");
    this.actionsBase = list;
    this.actionsBaseAttr = this.getAttribute("aria-actions");
    this.actionsVisible = null;
    this.actionsSet = true;
  }

  // ARIA reflection: the IDL property reads and writes its content attribute, null removing it.
  get role(): any { return this.getAttribute("role"); }
  set role(value: any) {
    if (value === null || value === undefined) this.removeAttribute("role");
    else this.setAttribute("role", String(value));
  }
  get ariaAtomic(): any { return this.getAttribute("aria-atomic"); }
  set ariaAtomic(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-atomic");
    else this.setAttribute("aria-atomic", String(value));
  }
  get ariaAutoComplete(): any { return this.getAttribute("aria-autocomplete"); }
  set ariaAutoComplete(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-autocomplete");
    else this.setAttribute("aria-autocomplete", String(value));
  }
  get ariaBrailleLabel(): any { return this.getAttribute("aria-braillelabel"); }
  set ariaBrailleLabel(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-braillelabel");
    else this.setAttribute("aria-braillelabel", String(value));
  }
  get ariaBrailleRoleDescription(): any { return this.getAttribute("aria-brailleroledescription"); }
  set ariaBrailleRoleDescription(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-brailleroledescription");
    else this.setAttribute("aria-brailleroledescription", String(value));
  }
  get ariaBusy(): any { return this.getAttribute("aria-busy"); }
  set ariaBusy(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-busy");
    else this.setAttribute("aria-busy", String(value));
  }
  get ariaChecked(): any { return this.getAttribute("aria-checked"); }
  set ariaChecked(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-checked");
    else this.setAttribute("aria-checked", String(value));
  }
  get ariaColCount(): any { return this.getAttribute("aria-colcount"); }
  set ariaColCount(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-colcount");
    else this.setAttribute("aria-colcount", String(value));
  }
  get ariaColIndex(): any { return this.getAttribute("aria-colindex"); }
  set ariaColIndex(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-colindex");
    else this.setAttribute("aria-colindex", String(value));
  }
  get ariaColIndexText(): any { return this.getAttribute("aria-colindextext"); }
  set ariaColIndexText(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-colindextext");
    else this.setAttribute("aria-colindextext", String(value));
  }
  get ariaColSpan(): any { return this.getAttribute("aria-colspan"); }
  set ariaColSpan(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-colspan");
    else this.setAttribute("aria-colspan", String(value));
  }
  get ariaCurrent(): any { return this.getAttribute("aria-current"); }
  set ariaCurrent(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-current");
    else this.setAttribute("aria-current", String(value));
  }
  get ariaDescription(): any { return this.getAttribute("aria-description"); }
  set ariaDescription(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-description");
    else this.setAttribute("aria-description", String(value));
  }
  get ariaDisabled(): any { return this.getAttribute("aria-disabled"); }
  set ariaDisabled(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-disabled");
    else this.setAttribute("aria-disabled", String(value));
  }
  get ariaExpanded(): any { return this.getAttribute("aria-expanded"); }
  set ariaExpanded(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-expanded");
    else this.setAttribute("aria-expanded", String(value));
  }
  get ariaHasPopup(): any { return this.getAttribute("aria-haspopup"); }
  set ariaHasPopup(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-haspopup");
    else this.setAttribute("aria-haspopup", String(value));
  }
  get ariaHidden(): any { return this.getAttribute("aria-hidden"); }
  set ariaHidden(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-hidden");
    else this.setAttribute("aria-hidden", String(value));
  }
  get ariaInvalid(): any { return this.getAttribute("aria-invalid"); }
  set ariaInvalid(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-invalid");
    else this.setAttribute("aria-invalid", String(value));
  }
  get ariaKeyShortcuts(): any { return this.getAttribute("aria-keyshortcuts"); }
  set ariaKeyShortcuts(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-keyshortcuts");
    else this.setAttribute("aria-keyshortcuts", String(value));
  }
  get ariaLabel(): any { return this.getAttribute("aria-label"); }
  set ariaLabel(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-label");
    else this.setAttribute("aria-label", String(value));
  }
  get ariaLevel(): any { return this.getAttribute("aria-level"); }
  set ariaLevel(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-level");
    else this.setAttribute("aria-level", String(value));
  }
  get ariaLive(): any { return this.getAttribute("aria-live"); }
  set ariaLive(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-live");
    else this.setAttribute("aria-live", String(value));
  }
  get ariaModal(): any { return this.getAttribute("aria-modal"); }
  set ariaModal(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-modal");
    else this.setAttribute("aria-modal", String(value));
  }
  get ariaMultiLine(): any { return this.getAttribute("aria-multiline"); }
  set ariaMultiLine(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-multiline");
    else this.setAttribute("aria-multiline", String(value));
  }
  get ariaMultiSelectable(): any { return this.getAttribute("aria-multiselectable"); }
  set ariaMultiSelectable(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-multiselectable");
    else this.setAttribute("aria-multiselectable", String(value));
  }
  get ariaOrientation(): any { return this.getAttribute("aria-orientation"); }
  set ariaOrientation(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-orientation");
    else this.setAttribute("aria-orientation", String(value));
  }
  get ariaPlaceholder(): any { return this.getAttribute("aria-placeholder"); }
  set ariaPlaceholder(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-placeholder");
    else this.setAttribute("aria-placeholder", String(value));
  }
  get ariaPosInSet(): any { return this.getAttribute("aria-posinset"); }
  set ariaPosInSet(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-posinset");
    else this.setAttribute("aria-posinset", String(value));
  }
  get ariaPressed(): any { return this.getAttribute("aria-pressed"); }
  set ariaPressed(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-pressed");
    else this.setAttribute("aria-pressed", String(value));
  }
  get ariaReadOnly(): any { return this.getAttribute("aria-readonly"); }
  set ariaReadOnly(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-readonly");
    else this.setAttribute("aria-readonly", String(value));
  }
  get ariaRelevant(): any { return this.getAttribute("aria-relevant"); }
  set ariaRelevant(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-relevant");
    else this.setAttribute("aria-relevant", String(value));
  }
  get ariaRequired(): any { return this.getAttribute("aria-required"); }
  set ariaRequired(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-required");
    else this.setAttribute("aria-required", String(value));
  }
  get ariaRoleDescription(): any { return this.getAttribute("aria-roledescription"); }
  set ariaRoleDescription(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-roledescription");
    else this.setAttribute("aria-roledescription", String(value));
  }
  get ariaRowCount(): any { return this.getAttribute("aria-rowcount"); }
  set ariaRowCount(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-rowcount");
    else this.setAttribute("aria-rowcount", String(value));
  }
  get ariaRowIndex(): any { return this.getAttribute("aria-rowindex"); }
  set ariaRowIndex(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-rowindex");
    else this.setAttribute("aria-rowindex", String(value));
  }
  get ariaRowIndexText(): any { return this.getAttribute("aria-rowindextext"); }
  set ariaRowIndexText(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-rowindextext");
    else this.setAttribute("aria-rowindextext", String(value));
  }
  get ariaRowSpan(): any { return this.getAttribute("aria-rowspan"); }
  set ariaRowSpan(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-rowspan");
    else this.setAttribute("aria-rowspan", String(value));
  }
  get ariaSelected(): any { return this.getAttribute("aria-selected"); }
  set ariaSelected(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-selected");
    else this.setAttribute("aria-selected", String(value));
  }
  get ariaSetSize(): any { return this.getAttribute("aria-setsize"); }
  set ariaSetSize(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-setsize");
    else this.setAttribute("aria-setsize", String(value));
  }
  get ariaSort(): any { return this.getAttribute("aria-sort"); }
  set ariaSort(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-sort");
    else this.setAttribute("aria-sort", String(value));
  }
  get ariaValueMax(): any { return this.getAttribute("aria-valuemax"); }
  set ariaValueMax(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-valuemax");
    else this.setAttribute("aria-valuemax", String(value));
  }
  get ariaValueMin(): any { return this.getAttribute("aria-valuemin"); }
  set ariaValueMin(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-valuemin");
    else this.setAttribute("aria-valuemin", String(value));
  }
  get ariaValueNow(): any { return this.getAttribute("aria-valuenow"); }
  set ariaValueNow(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-valuenow");
    else this.setAttribute("aria-valuenow", String(value));
  }
  get ariaValueText(): any { return this.getAttribute("aria-valuetext"); }
  set ariaValueText(value: any) {
    if (value === null || value === undefined) this.removeAttribute("aria-valuetext");
    else this.setAttribute("aria-valuetext", String(value));
  }

  /**
   * The element's attributes as a list of Attr, in the order a browser lists them: id, class,
   * style and hidden first, then the rest in the order they were set.
   */
  get attributes(): NamedNodeMap {
    return new NamedNodeMap(this);
  }

  /**
   * Every attribute name the element carries, in the order they were first set: a browser lists
   * attributes in the order the element got them, whatever storage a special one lives in.
   */
  attributeNames(): string[] {
    const out: string[] = [];
    for (const name of this.attrOrder) if (this.getAttribute(name) !== null) out.push(name);
    return out;
  }

  /**
   * Records an attribute that is set through a slot of its own (the id, say), after the slot
   * holds its value: `attributes` lists it in the order the element got it.
   */
  recordSlotAttribute(name: string): void {
    if (this.getAttribute(name) !== null && this.attrOrder.indexOf(name) < 0) this.attrOrder.push(name);
  }

  /** Takes another element's attribute order, for the copies an upgrade makes. */
  copyAttributeOrder(from: Element): void {
    for (const name of from.attributeNames()) if (this.attrOrder.indexOf(name) < 0) this.attrOrder.push(name);
  }

  /** Records that an attribute was first set, for the order `attributes` lists them in. */
  private noteAttrOrder(key: string): void {
    if (this.getAttribute(key) === null && this.attrOrder.indexOf(key) < 0) this.attrOrder.push(key);
  }

  /**
   * The name an attribute is stored under: HTML and SVG elements read and write attribute names
   * case-insensitively, while XML elements of another namespace keep the case they were given.
   * SVG's names are case-sensitive in a browser, but the build's HTML parser lowercases every
   * name it reads, and the SVG paint reads them back that way, so a name a script sets reaches
   * the same attribute as one written in the markup.
   */
  private attrKey(name: any): string {
    const text = String(name);
    const ns = this.namespaceURI;
    return ns === "http://www.w3.org/1999/xhtml" || ns === "http://www.w3.org/2000/svg" ? text.toLowerCase() : text;
  }

  getAttribute(name: string): string | null {
    const key = this.attrKey(name);
    const own = this.nullNamespaceAttribute(key);
    if (own !== null) return own;
    // A namespaced attribute is reachable by its qualified name too, as a browser has it.
    const namespaced = this.nsAttributeNamed(key);
    return namespaced === null ? null : namespaced.value;
  }

  /** The value of the attribute with this name and no namespace, if the element has one. */
  private nullNamespaceAttribute(key: string): string | null {
    // id and class have no separate presence bit: an empty one counts as absent, so that
    // [id] and [class] only match elements that actually carry one.
    if (key === "id") return this.idValue === "" ? null : this.idValue;
    if (key === "class") {
      const v = this.classList.value;
      return v === "" ? null : v;
    }
    if (key === "hidden") return this.hiddenFlag ? "" : null;
    if (key === "style") return this.styleDecl !== null && this.styleDecl.present ? this.styleDecl.cssText : null;
    const v = this.attrMap.get(key);
    return v === undefined ? null : v;
  }
  /** A renderer passes the property it was given, so a boolean like `disabled: true` arrives
   *  as a boolean; the DOM stringifies it, as a browser does. */
  /** The attribute node for a name, or null: a snapshot of the value the element holds. */
  getAttributeNode(name: string): Attr | null {
    const key = this.attrKey(name);
    const namespaced = this.nsAttributeNamed(key);
    if (namespaced !== null) return namespaced;
    const v = this.getAttribute(key);
    return v === null ? null : new Attr(key, v, this);
  }
  /** Attaches an attribute node (one createAttribute made); returns the node it replaced. */
  setAttributeNode(attr: Attr): Attr | null {
    const old = this.getAttributeNode(attr.name);
    if (attr.namespaceURI !== null) this.setAttributeNS(attr.namespaceURI, attr.name, attr.value);
    else this.setAttribute(attr.name, attr.value);
    return old;
  }
  /** Takes an attribute node off the element; returns the node it held. */
  removeAttributeNode(attr: Attr): Attr {
    this.removeAttribute(attr.name);
    return attr;
  }
  setAttribute(name: string, value: any): void {
    const key = this.attrKey(name);
    if (key === "") {
      throw new Error("InvalidCharacterError: Failed to execute 'setAttribute' on 'Element': The name is empty.");
    }
    const text = value === null || value === undefined ? "" : typeof value === "string" ? value : String(value);
    // Any attribute can be one a presentation hint reads (an SVG fill, a source of geometry
    // the painter draws), so the declarations the attributes stand for are read again.
    this.hintStale = true;
    this.noteAttrOrder(key);
    if (key === "id") this.id = text;
    else if (key === "class") this.className = text;
    else if (key === "hidden") this.hidden = true;
    else if (key === "style") {
      // A style change is an attribute change too, and style is kept off attrMap, so it reports
      // itself here rather than through noteAttribute().
      const old = this.getAttribute("style");
      noteOtherIdentityChange(this);
      this.setStyleText(text);
      notifyAttribute(this, "style", old);
    }
    else {
      // Attribute selectors can depend on any attribute, so the style must be recomputed.
      const old = this.attrMap.get(key);
      if (old !== text) {
        this.attrMap.set(key, text);
        noteAttribute(this, key, old === undefined ? null : old);
        noteOtherIdentityChange(this);
        if (this.isConnected) invalidateStyleOf(this);
        noteSheetAttr(this, key, text);
      }
    }
  }
  removeAttribute(name: string): void {
    const key = this.attrKey(name);
    this.hintStale = true;
    const at = this.attrOrder.indexOf(key);
    if (at >= 0) this.attrOrder.splice(at, 1);
    if (key === "id") this.id = "";
    else if (key === "hidden") this.hidden = false;
    else if (key === "class") this.className = "";
    else if (key === "style") {
      if (this.styleDecl !== null) {
        const old = this.getAttribute("style");
        noteOtherIdentityChange(this);
        this.styleDecl.clear();
        notifyAttribute(this, "style", old);
      }
    } else {
      const old = this.attrMap.get(key);
      if (this.attrMap.delete(key)) {
        noteAttribute(this, key, old === undefined ? null : old);
        noteOtherIdentityChange(this);
        if (this.isConnected) invalidateStyleOf(this);
        noteSheetAttr(this, key, null);
      }
      const namespaced = this.nsAttributeNamed(key);
      if (namespaced !== null && this.nsAttrs !== null) {
        this.nsAttrs.delete(this.nsKey(namespaced.namespaceURI === null ? "" : namespaced.namespaceURI, namespaced.localName));
        noteAttribute(this, namespaced.name, namespaced.value);
        noteOtherIdentityChange(this);
      }
    }
  }
  hasAttribute(name: string): boolean {
    return this.getAttribute(this.attrKey(name)) !== null;
  }

  // --- Namespaced attributes ----------------------------------------------
  //
  // An attribute set with a namespace keeps its qualified name in the ordinary store (so
  // getAttribute and the selectors see it) and its namespace, prefix and local name in a map
  // keyed by namespace and local name. Attributes set without one are the null-namespace ones.

  private nsKey(ns: string, local: string): string {
    return ns + "|" + local;
  }

  setAttributeNS(namespace: string | null, qualifiedName: any, value: any): void {
    const qname = String(qualifiedName);
    if (qname === "") throw new Error("InvalidCharacterError: Failed to execute 'setAttributeNS' on 'Element': The name is empty.");
    const text = value === null || value === undefined ? "" : String(value);
    // A null namespace is setAttribute's own table; a namespaced attribute lives beside it, so
    // getAttributeNS and the `attributes` list keep the namespace, prefix and local name.
    if (namespace === null || namespace === "") {
      this.setAttribute(qname, text);
      return;
    }
    const colon = qname.indexOf(":");
    const prefix = colon > 0 ? qname.slice(0, colon) : null;
    const local = colon > 0 ? qname.slice(colon + 1) : qname;
    if (this.nsAttrs === null) this.nsAttrs = new Map();
    const key = this.nsKey(namespace, local);
    const old = this.nsAttrs.get(key);
    if (this.attrOrder.indexOf(qname) < 0) this.attrOrder.push(qname);
    this.nsAttrs.set(key, new Attr(qname, text, this, namespace, prefix, local));
    this.hintStale = true;
    noteAttribute(this, qname, old === undefined ? null : old.value);
    noteOtherIdentityChange(this);
  }

  /** The namespaced attribute whose qualified name matches `key`, or null. */
  private nsAttributeNamed(key: string): Attr | null {
    if (this.nsAttrs === null) return null;
    for (const attr of this.nsAttrs.values()) {
      if (this.attrKey(attr.name) === key) return attr;
    }
    return null;
  }

  getAttributeNS(namespace: string | null, localName: any): string | null {
    const local = String(localName);
    const ns = namespace === null ? "" : namespace;
    if (ns !== "") {
      const a = this.nsAttrs === null ? undefined : this.nsAttrs.get(this.nsKey(ns, local));
      return a === undefined ? null : a.value;
    }
    // A null-namespace name is matched exactly, unlike getAttribute's HTML lowercasing, and a
    // namespaced attribute with the same local name doesn't answer for it.
    if (this.attrKey(local) !== local) return null;
    return this.nullNamespaceAttribute(local);
  }

  hasAttributeNS(namespace: string | null, localName: any): boolean {
    return this.getAttributeNS(namespace, localName) !== null;
  }

  removeAttributeNS(namespace: string | null, localName: any): void {
    const local = String(localName);
    const ns = namespace === null ? "" : namespace;
    if (ns === "") {
      this.removeAttribute(local);
      return;
    }
    if (this.nsAttrs === null) return;
    const key = this.nsKey(ns, local);
    const a = this.nsAttrs.get(key);
    if (a === undefined) return;
    const at = this.attrOrder.indexOf(a.name);
    if (at >= 0) this.attrOrder.splice(at, 1);
    this.nsAttrs.delete(key);
    this.removeAttribute(a.name);
  }

  getAttributeNodeNS(namespace: string | null, localName: any): Attr | null {
    const local = String(localName);
    const ns = namespace === null ? "" : namespace;
    if (ns !== "") {
      const a = this.nsAttrs === null ? undefined : this.nsAttrs.get(this.nsKey(ns, local));
      return a === undefined ? null : a;
    }
    const v = this.getAttributeNS(null, local);
    return v === null ? null : new Attr(local, v, this);
  }

  setAttributeNodeNS(attr: Attr): Attr | null {
    const old = this.getAttributeNodeNS(attr.namespaceURI, attr.localName);
    this.setAttributeNS(attr.namespaceURI, attr.name, attr.value);
    return old;
  }
  toggleAttribute(name: string, force?: boolean): boolean {
    const key = this.attrKey(name);
    if (key === "") {
      throw new Error("InvalidCharacterError: Failed to execute 'toggleAttribute' on 'Element': The name is empty.");
    }
    const has = this.hasAttribute(key);
    const want = force === undefined ? !has : force;
    if (want && !has) this.setAttribute(key, "");
    else if (!want && has) this.removeAttribute(key);
    return want;
  }

  // --- Markup --------------------------------------------------------------

  /** The element's children as HTML text; setting it parses the text into new children. */
  get innerHTML(): string {
    return markupOfChildren(this);
  }
  set innerHTML(html: string) {
    this.replaceChildren(...parseFragment(html));
  }
  /** Parses markup that may hold declarative shadow roots, replacing this element's children. */
  setHTMLUnsafe(html: string): void {
    const nodes = parseFragment(String(html));
    const keep: Node[] = [];
    for (const n of nodes) {
      if (n instanceof HTMLTemplateElement && adoptDeclarative(this, n)) continue;
      keep.push(n);
    }
    for (const n of keep) adoptDeclarativeIn(n);
    this.replaceChildren(...keep);
  }
  /**
   * Serializes this element's children, with the shadow roots the options name (or all serializable
   * ones) — its own root included, ahead of the light content, as HTML serializes a fragment.
   */
  getHTML(options: GetHTMLOptions = {}): string {
    const root = serializedRoot(this, options);
    const own = root === null ? "" : shadowTemplateMarkup(root, options);
    return own + markupOfChildren(this, options);
  }
  /** The element itself as HTML text; setting it replaces the element with parsed nodes. */
  get outerHTML(): string {
    return markupOf(this);
  }
  set outerHTML(html: string) {
    const parent = this.parentNode;
    if (parent === null) throw new Error("NoModificationAllowedError: the element has no parent");
    const nodes = parseFragment(html);
    const at = parent.kids.indexOf(this);
    parent.removeChild(this);
    for (let i = 0; i < nodes.length; i++) {
      parent.kids.splice(at + i, 0, nodes[i]);
      nodes[i].parentNode = parent;
      refreshAdded(nodes[i]);
    }
    if (nodes.length > 0) noteChildList(parent, nodes, []);
    invalidateStyle();
  }

  insertAdjacentHTML(where: string, html: string): void {
    this.insertAdjacent(where, parseFragment(html), true);
  }
  insertAdjacentElement(where: string, element: Element): Element | null {
    return this.insertAdjacent(where, [element], false) === null ? null : element;
  }
  insertAdjacentText(where: string, data: string): void {
    this.insertAdjacent(where, [new Text(data)], true);
  }

  /** Inserts the nodes at one of the four positions around the element. A position beside the
   *  element needs a parent: inserting an element returns null there, as the DOM has it, while
   *  inserting markup throws; the other two positions always work. */
  private insertAdjacent(where: string, nodes: Node[], throwWhenParentless: boolean): Node[] | null {
    if (nodes.length === 0) return nodes;
    if (where === "afterbegin") {
      let ref = this.firstChild;
      for (const n of nodes) {
        this.insertBefore(n, ref);
        ref = n;
      }
      return nodes;
    }
    if (where === "beforeend") {
      for (const n of nodes) this.appendChild(n);
      return nodes;
    }
    if (where !== "beforebegin" && where !== "afterend") {
      throw new Error("SyntaxError: the position isn't a valid insertAdjacent position");
    }
    const parent = this.parentNode;
    if (parent === null) {
      if (throwWhenParentless) throw new Error("NoModificationAllowedError: the element has no parent");
      return null;
    }
    const ref = where === "beforebegin" ? this : this.nextSibling;
    for (const n of nodes) parent.insertBefore(n, ref);
    return nodes;
  }

  // --- Scrolling -----------------------------------------------------------

  // (scrollLeft is the DOM's reading of the box's own left-based offset; see scrollXOf below.)

  get scrollTop(): number {
    // A browser lays the page out before it answers a scroll position: the snap pass that runs
    // with the layout may have moved this box.
    const self: Element = this;
    flushStyleWork(self);
    flushLayoutHook();
    return domScrollYOf(self, this.scrollY);
  }
  // scrollTop and scrollLeft are WebIDL `double`s: a page may assign the string a WPT test
  // writes ("1000"), and the IDL converts it to a number rather than the assignment failing.
  set scrollTop(v: number | string) {
    // A box that isn't a scroll container on this axis has nothing to scroll: `overflow: clip`
    // and `visible` keep their offset at 0. The root element is the viewport's scroller and
    // takes the offset whatever its own overflow. Whether the box scrolls is its computed
    // overflow, so the style behind the first write of a page's script has to be there.
    const self: Element = this;
    const own = self.ownerDocument;
    flushStyleWork(self);
    // The overflow that decides whether this box scrolls is a computed value: settle the layout
    // too, as the getters do, so the first write of a page's script sees the real overflow.
    flushLayoutHook();
    if ((own === null || self !== own.documentElement) && !scriptScrollsY(self)) return;
    this.scriptScrollTo(this.scrollX, scrollYOf(self, Number(v)), "", false, true);
  }
  get scrollLeft(): number {
    const self: Element = this;
    flushStyleWork(self);
    flushLayoutHook();
    return domScrollXOf(self, this.scrollX);
  }
  set scrollLeft(v: number | string) {
    const self: Element = this;
    const own = self.ownerDocument;
    flushStyleWork(self);
    // See scrollTop: the box's overflow has to be computed before it can be asked about.
    flushLayoutHook();
    if ((own === null || self !== own.documentElement) && !scriptScrollsX(self)) return;
    this.scriptScrollTo(scrollXOf(self, Number(v)), this.scrollY, "", true, false);
  }

  /** `scroll()` and `scrollTo()`: a script's scroll to an offset, with the DOM's two forms. */
  scroll(options?: ScrollToOptions): void;
  scroll(x: number, y: number): void;
  scroll(options: ScrollToOptions | number = {}, y?: number): void {
    const [x, y2, behavior, snapX, snapY] = this.scrollTarget(options, y, false);
    this.scriptScrollTo(x, y2, behavior, snapX, snapY);
  }
  scrollTo(options?: ScrollToOptions): void;
  scrollTo(x: number, y: number): void;
  scrollTo(options: ScrollToOptions | number = {}, y?: number): void {
    const [x, y2, behavior, snapX, snapY] = this.scrollTarget(options, y, false);
    this.scriptScrollTo(x, y2, behavior, snapX, snapY);
  }
  /** `scrollBy()`: the same, from where the box is now. */
  scrollBy(options?: ScrollToOptions): void;
  scrollBy(x: number, y: number): void;
  scrollBy(options: ScrollToOptions | number = {}, y?: number): void {
    const [x, y2, behavior, snapX, snapY] = this.scrollTarget(options, y, true);
    this.scriptScrollTo(x, y2, behavior, snapX, snapY);
  }
  /**
   * A scroll's offsets and behavior from the DOM's arguments: a pair of numbers, or options. The
   * flags name the axes the scroll sets, which are the ones it snaps on: a scroll to a pair of
   * numbers sets both, and a relative one only touches the axes it moves.
   */
  private scrollTarget(options: ScrollToOptions | number, y: number | undefined, relative: boolean): [number, number, string, boolean, boolean] {
    // The coordinates a script names are the DOM's: an RTL box's scrollLeft counts from its right
    // edge, so each one is turned into this box's own left-based offset — which needs the box's
    // scroll extent, so pending layout is settled first, as the scroll itself does.
    const self: Element = this;
    flushStyleWork(self);
    flushLayoutHook();
    const from = domScrollXOf(self, this.scrollX);
    const fromY = domScrollYOf(self, this.scrollY);
    if (typeof options === "number") {
      const dx = options;
      const dy = y === undefined ? 0 : y;
      return relative
        ? [scrollXOf(self, from + dx), scrollYOf(self, fromY + dy), "", dx !== 0, dy !== 0]
        : [scrollXOf(self, dx), scrollYOf(self, dy), "", true, true];
    }
    const dx = options.left === undefined ? 0 : options.left;
    const dy = options.top === undefined ? 0 : options.top;
    const behavior = options.behavior === undefined ? "" : options.behavior;
    if (relative) {
      return [scrollXOf(self, from + dx), scrollYOf(self, fromY + dy), behavior,
        options.left !== undefined && dx !== 0, options.top !== undefined && dy !== 0];
    }
    return [scrollXOf(self, options.left === undefined ? from : options.left),
      scrollYOf(self, options.top === undefined ? fromY : options.top), behavior,
      options.left !== undefined, options.top !== undefined];
  }

  /**
   * A script's scroll of this box: the offsets clamp to what it can scroll, an axis it can't
   * scroll staying put, and a snap container lands on a snap position rather than the offset it
   * asks for, on the axes the scroll sets. `behavior` is the DOM's word for it — `instant` jumps,
   * `smooth` travels — and `auto`, or an empty string, follows the box's computed scroll-behavior.
   */
  scriptScrollTo(x: number, y: number, behavior: string, snapX = true, snapY = true): void {
    const self: Element = this;
    // The box's computed scroll-behavior decides an `auto` scroll, and a class set a moment ago
    // counts, as it does in a browser. A scroll's clamp reads the box's scroll extent, so the page
    // is laid out first, as a browser forces layout for a scroll.
    flushStyleWork(self);
    flushLayoutHook();
    // The snap positions are read off the boxes as they are now, and the scroll lands on one of
    // them instead of the offset asked for (CSS Scroll Snap 1, 6.2).
    const landed = snapScrollPositionHook(this, x, y, snapX, snapY);
    const next = this.clampedScroll(landed[0], landed[1]);
    if (next[0] === this.scrollX && next[1] === this.scrollY) {
      // A scroll that asks for where the box already is still stops a journey towards elsewhere.
      cancelSmoothScrollHook(this);
      return;
    }
    const travel = behavior === "smooth" ||
      (behavior !== "instant" && this.sv[P.P_SCROLL_BEHAVIOR] === P.SB_SMOOTH);
    if (travel) smoothScrollHook(this, next[0], next[1]);
    else {
      cancelSmoothScrollHook(this);
      this.scrollInstant(next[0], next[1]);
    }
  }

  /** Sets the offsets at once, for the runtime's own scrolling: no behavior, no animation. */
  scrollInstant(x: number, y: number): void {
    const next = this.clampedScroll(x, y);
    if (next[0] === this.scrollX && next[1] === this.scrollY) return;
    this.scrollX = next[0];
    this.scrollY = next[1];
    // A marker group's :target-current moves with the scrollport, so the style work is due again.
    if ((stateUsage.mask & P.S_TARGET_CURRENT) !== 0) invalidateStyle();
    // The paint put this box's content under a transform the compositor can move: a scroll step
    // edits it instead of painting the page again. A scrollbar that had faded has to appear with
    // this scroll, which only a paint can draw, so the first step of a gesture paints.
    // Any scroll shows the overlay scrollbar, as a browser's does, and it fades again once the
    // scrolling stops. A bar that had faded has to be drawn with this scroll, which a paint does;
    // after that the frame composites and carries the thumb.
    const faded = scrollBarState(this) === BAR_FADED;
    noteScroll(this);
    const composited = updateScroll(this, this.scrollX, this.scrollY, this.clientWidth,
      this.clientHeight, this.scrollWidth, this.scrollHeight);
    if (faded || !composited) {
      // A scroll repaints the scrollport and nothing else: the page around it keeps its pixels.
      const box = this.getBoundingClientRect();
      markPaintRects([[box.left, box.top, box.width, box.height]]);
    }
  }

  /**
   * The offsets a scroll to (x, y) lands on: clamped to what the box can scroll, and kept as they
   * are on an axis it can't. The root element scrolls the viewport whatever its own overflow.
   */
  private clampedScroll(x: number, y: number): [number, number] {
    const self: Element = this;
    const own = self.ownerDocument;
    const root = own !== null && self === own.documentElement;
    const nx = root || scriptScrollsX(self) ? Math.max(0, Math.min(x, this.scrollWidth - this.clientWidth)) : this.scrollX;
    const ny = root || scriptScrollsY(self) ? Math.max(0, Math.min(y, this.scrollHeight - this.clientHeight)) : this.scrollY;
    return [nx, ny];
  }
  /** A used border width: the collapsed model's share when it has one, else the computed width. */
  usedBorder(side: number, p: number): number {
    return this.bw.length > 0 ? this.bw[side] : this.sv[p];
  }
  get scrollHeight(): number {
    // A read settles the pending style and layout first, as a browser's does.
    flushLayoutHook();
    // A box that isn't generated has no scrolling to report, whatever its last layout left.
    if (isUnrendered(this)) return 0;
    // A textarea's rows fix its box, so what it can scroll is the text it has wrapped, not the box.
    if (this.localName === "textarea") {
      const el = this as Node;
      return Math.max(el.lines.length * lineHeightPx(el) + padV(el, 0), this.clientHeight);
    }
    return Math.max(this.naturalH - this.usedBorder(0, P.P_BORDER_TOP_WIDTH) - this.usedBorder(2, P.P_BORDER_BOTTOM_WIDTH),
      this.clientHeight);
  }
  get clientHeight(): number {
    // A read forces the pending style and layout, as a browser's does.
    flushLayoutHook();
    // A box that isn't generated has no client area, whatever its last layout left behind.
    if (isUnrendered(this)) return 0;
    // The root's visible part is the viewport, whatever height its box grew to.
    if ((this as Node) === document.documentElement) return viewport.h;
    return Math.max(0, this.h - this.usedBorder(0, P.P_BORDER_TOP_WIDTH) - this.usedBorder(2, P.P_BORDER_BOTTOM_WIDTH));
  }
  get clientWidth(): number {
    flushLayoutHook();
    // A box that isn't generated has no client area, whatever its last layout left behind.
    if (isUnrendered(this)) return 0;
    // The root's visible part is the viewport, whatever width its box grew to.
    if ((this as Node) === document.documentElement) return viewport.w;
    return Math.max(0, this.w - this.usedBorder(3, P.P_BORDER_LEFT_WIDTH) - this.usedBorder(1, P.P_BORDER_RIGHT_WIDTH));
  }
  get scrollWidth(): number {
    flushLayoutHook();
    if (isUnrendered(this)) return 0;
    // How far the content reaches past the content box, added to what the box shows: a browser
    // does not let the box's own padding count as scrollable overflow.
    const over = this.naturalW - this.contentX - this.contentW;
    return this.clientWidth + (over > 0 ? over : 0);
  }
  get borderWidth(): number {
    return this.usedBorder(0, P.P_BORDER_TOP_WIDTH);
  }
  get borderTopWidth(): number {
    return this.usedBorder(0, P.P_BORDER_TOP_WIDTH);
  }
  get borderRightWidth(): number {
    return this.usedBorder(1, P.P_BORDER_RIGHT_WIDTH);
  }
  get borderBottomWidth(): number {
    return this.usedBorder(2, P.P_BORDER_BOTTOM_WIDTH);
  }
  get borderLeftWidth(): number {
    return this.usedBorder(3, P.P_BORDER_LEFT_WIDTH);
  }
  get offsetHeight(): number {
    flushLayoutHook();
    // A box that isn't generated measures nothing, whatever size its last layout gave it.
    return isUnrendered(this) ? 0 : this.h;
  }
  get offsetWidth(): number {
    flushLayoutHook();
    // A box that isn't generated measures nothing, whatever size its last layout gave it.
    return isUnrendered(this) ? 0 : this.w;
  }
  /** The ancestor offsets are measured from, or null when they come from the initial containing
   *  block (CSSOM View's rule: the nearest positioned ancestor, a table or a table cell). */
  get offsetParent(): Element | null {
    flushLayoutHook();
    // A box that isn't generated has nothing to measure from.
    if (isUnrendered(this)) return null;
    const p = geometry.offsetParent(this);
    return p instanceof Element ? p : null;
  }
  get offsetLeft(): number {
    // A read of an offset settles the pending style and layout first, as offsetWidth does and as
    // a browser does: a style set since the last frame is measured, not the box before it.
    flushLayoutHook();
    return isUnrendered(this) ? 0 : geometry.offsetLeft(this);
  }
  get offsetTop(): number {
    flushLayoutHook();
    return isUnrendered(this) ? 0 : geometry.offsetTop(this);
  }

  /**
   * The border box in viewport coordinates, after scrolling. An inline box reports the union of
   * its client rects instead: its own box has no size, since the line it sits on is what sizes
   * it. A box that isn't generated (display: none) has no rect at all, and neither has one with
   * no client rects.
   */
  getBoundingClientRect(): DOMRect {
    // A read forces the pending style and layout, as a browser's does.
    flushLayoutHook();
    if (isUnrendered(this)) return new DOMRect(0, 0, 0, 0);
    if (isInlineBox(this)) {
      const rects = inlineClientRects(this);
      if (rects.length === 0) return new DOMRect(0, 0, 0, 0);
      let left = rects[0].left;
      let top = rects[0].top;
      let right = rects[0].right;
      let bottom = rects[0].bottom;
      for (const r of rects) {
        if (r.left < left) left = r.left;
        if (r.top < top) top = r.top;
        if (r.right > right) right = r.right;
        if (r.bottom > bottom) bottom = r.bottom;
      }
      return new DOMRect(left, top, right - left, bottom - top);
    }
    const o = viewportOrigin(this);
    return new DOMRect(o[0], o[1], this.w, this.h);
  }

  /**
   * The rects the element paints in: one per piece of an inline box, since a line can break it
   * into several, and each piece is as tall as the font box, not as tall as its line. Any other
   * box paints one rect, its border box.
   */
  getClientRects(): DOMRect[] {
    if (isUnrendered(this)) return [];
    if (isInlineBox(this)) return inlineClientRects(this);
    return [this.getBoundingClientRect()];
  }
  get clientLeft(): number {
    return this.usedBorder(3, P.P_BORDER_LEFT_WIDTH);
  }
  get clientTop(): number {
    return this.usedBorder(0, P.P_BORDER_TOP_WIDTH);
  }
  /**
   * Scrolls the box's scroll containers so it shows. `block` and `inline` say which edge to line
   * up with — `start`, `center`, `end` or `nearest` — and `behavior` whether the scroll travels;
   * `auto` follows each container's computed scroll-behavior. `true`/`false` are the legacy
   * spelling of `start`/`end` on the block axis.
   */
  scrollIntoView(arg?: boolean | ScrollIntoViewOptions): void {
    const o: ScrollIntoViewOptions = typeof arg === "boolean"
      ? { block: arg ? "start" : "end" } : arg === undefined ? {} : arg;
    pendingScrollIntoView.el = this;
    pendingScrollIntoView.block = o.block === undefined ? "start" : o.block;
    pendingScrollIntoView.inline = o.inline === undefined ? "nearest" : o.inline;
    pendingScrollIntoView.behavior = o.behavior === undefined ? "" : o.behavior;
    // The scroll is made once layout runs; no box's own layout changes for it.
    dirty.layout = true;
    dirty.paint = true;
  }

  /**
   * Points a runtime-created element's ::before or ::after at the rules its selector table
   * matched, creating the pseudo child the first time a rule generates content for it.
   */
  /** The pseudo-element objects this element handed out, one per type. */
  private pseudoCache: Map<string, CSSPseudoElement> | null = null;

  /** The pseudo-element of this element for a type such as "::before", the same object each call. */
  pseudo(type: string): CSSPseudoElement | null {
    const t = String(type).trim().toLowerCase();
    if (!KNOWN_PSEUDO_TYPES.has(t)) return null;
    if (this.pseudoCache === null) this.pseudoCache = new Map();
    let p = this.pseudoCache.get(t);
    if (p === undefined) {
      p = new CSSPseudoElement(t, this, this);
      this.pseudoCache.set(t, p);
    }
    return p;
  }

  /**
   * The generated box a pseudo-element type names, if the page has one: the box an animation
   * targeting that pseudo-element animates, or null when nothing generated it.
   */
  pseudoBox(type: string): Element | null {
    const t = String(type).trim().toLowerCase();
    if (t === "::before") return this.beforePseudo;
    if (t === "::after") return this.afterPseudo;
    if (t === "::marker") return this.markerPseudo;
    if (t === "::placeholder") return this.placeholderPseudo;
    if (t === "::backdrop") return this.backdropPseudo;
    if (t === "::first-line") return this.firstLinePseudo;
    if (t === "::first-letter") return this.firstLetterPseudo;
    if (t === "::selection") return this.selectionPseudo;
    return null;
  }

  /**
   * Adds rules to the style carrier of one kind, making the carrier first if the page has none.
   * A rule whose class or state only starts matching after a change (`.on::target-text`) reaches
   * the carrier this way; one already on it isn't added twice.
   */
  addCarrierRules(kind: number, rules: readonly number[]): void {
    if (rules.length === 0) return;
    const box = this.carrierBox(kind);
    if (box === null) {
      this.setCarrierRules(kind, rules);
      return;
    }
    let merged: number[] | null = null;
    for (const r of rules) {
      if ((merged === null ? box.rules : merged).indexOf(r) >= 0) continue;
      if (merged === null) merged = box.rules.slice();
      merged.push(r);
    }
    if (merged !== null) box.rules = merged;
  }

  /** The style carrier of one fixed kind, or null when the page has none yet. */
  private carrierBox(kind: number): Element | null {
    if (kind === P.PE_FIRST_LINE) return this.firstLinePseudo;
    if (kind === P.PE_FIRST_LETTER) return this.firstLetterPseudo;
    if (kind === P.PE_SELECTION) return this.selectionPseudo;
    if (kind === P.PE_TARGET_TEXT) return this.targetTextPseudo;
    if (kind === P.PE_BACKDROP) return this.backdropPseudo;
    return null;
  }

  setPseudoRules(kind: number, rules: readonly number[]): void {
    if (kind === P.PE_PLACEHOLDER) {
      const p = this.placeholderPseudo;
      if (p === null) {
        if (rules.length === 0) return;
        this.addPseudoChild(kind, rules);
        return;
      }
      p.rules = rules;
      return;
    }
    const p = kind === P.PE_BEFORE ? this.beforePseudo : this.afterPseudo;
    if (p === null) {
      if (rules.length === 0) return;
      // Any own text becomes a text node, so the generated box can sit beside it.
      materializeText(this);
      this.addPseudoChild(kind, rules);
      return;
    }
    p.rules = rules;
  }

  /**
   * The style carrier of one fixed kind — ::first-line, ::first-letter, ::selection,
   * ::target-text, a ::backdrop — for a rule that only starts matching at runtime (a class
   * change, say). The carrier is a display:none child the first time a rule reaches the element;
   * the style pass walks it with the rest of the children.
   */
  setCarrierRules(kind: number, rules: readonly number[]): void {
    if (rules.length === 0) return;
    let box: Element | null =
      kind === P.PE_FIRST_LINE ? this.firstLinePseudo
        : kind === P.PE_FIRST_LETTER ? this.firstLetterPseudo
        : kind === P.PE_SELECTION ? this.selectionPseudo
        : kind === P.PE_TARGET_TEXT ? this.targetTextPseudo
        : kind === P.PE_BACKDROP ? this.backdropPseudo
        : null;
    if (box === null) {
      box = newElementFor(P.PSEUDO_TAGS[kind], "", "", rules, 0, false);
      box.parentNode = this;
      this.kids.push(box);
      if (kind === P.PE_FIRST_LINE) this.firstLinePseudo = box;
      else if (kind === P.PE_FIRST_LETTER) this.firstLetterPseudo = box;
      else if (kind === P.PE_SELECTION) this.selectionPseudo = box;
      else if (kind === P.PE_TARGET_TEXT) this.targetTextPseudo = box;
      else this.backdropPseudo = box;
      return;
    }
    box.rules = rules;
  }

  /**
   * The marker box of a list item, made on demand: every list item has one, whether or not a
   * ::marker rule styles it. Its text comes from the item's list-style-type and ordinal.
   */
  ensureMarker(): Element {
    if (this.markerPseudo === null) {
      materializeText(this);
      this.addPseudoChild(P.PE_MARKER, this.markerRules);
    }
    return this.markerPseudo!;
  }

  /** Whether this element already has the generated box of one kind. */
  hasPseudoBox(kind: number): boolean {
    if (kind === P.PE_BEFORE) return this.beforePseudo !== null;
    if (kind === P.PE_AFTER) return this.afterPseudo !== null;
    if (kind === P.PE_MARKER) return this.markerPseudo !== null;
    if (kind === P.PE_PLACEHOLDER) return this.placeholderPseudo !== null;
    if (kind === P.PE_BACKDROP) return this.backdropPseudo !== null;
    return false;
  }

  /**
   * Makes the generated box of one kind for a runtime sheet rule that generates content for it;
   * the compiled cascade made its boxes at build time, and style.ts asks here for the rest.
   */
  ensurePseudoBox(kind: number): Element | null {
    if (kind === P.PE_MARKER) return this.ensureMarker();
    if (kind === P.PE_PLACEHOLDER) {
      if (this.placeholderPseudo === null && this.localName === "input") this.addPseudoChild(kind, []);
      return this.placeholderPseudo;
    }
    const existing = kind === P.PE_BEFORE ? this.beforePseudo : kind === P.PE_AFTER ? this.afterPseudo : null;
    if (existing === null) {
      // Any own text becomes a text node, so the generated box can sit beside it.
      materializeText(this);
      this.addPseudoChild(kind, []);
    }
    return kind === P.PE_BEFORE ? this.beforePseudo! : this.afterPseudo!;
  }

  /** Appends a pseudo child, keeping the order marker, ::before, content, ::after. */
  private addPseudoChild(kind: number, rules: readonly number[]): void {
    const p = newPlainElement(P.PSEUDO_TAGS[kind], "", "", rules, 0, false);
    p.parentNode = this;
    if (kind === P.PE_PLACEHOLDER) {
      // The field reads the placeholder box's style when it draws its text; the box itself is
      // display: none, so it takes no room and paints nothing.
      this.placeholderPseudo = p;
      this.kids.push(p);
    } else if (kind === P.PE_MARKER) {
      this.markerPseudo = p;
      this.kids.unshift(p);
    } else if (kind === P.PE_BEFORE) {
      this.beforePseudo = p;
      this.kids.splice(this.markerPseudo === null ? 0 : 1, 0, p);
    } else {
      this.afterPseudo = p;
      this.kids.push(p);
    }
  }

  get hidden(): boolean {
    return this.hiddenFlag;
  }
  set hidden(value: boolean) {
    if (this.hiddenFlag === value) return;
    const old = this.hiddenFlag ? "" : null;
    this.hiddenFlag = value;
    noteAttribute(this, "hidden", old);
    invalidateLayout();
  }

  /**
   * The `inert` attribute, which takes the element's subtree out of the tab order and out of
   * the pointer's reach: as in a browser, `inert` is the element's own attribute and a child
   * inside an inert subtree is inert too (see inertRoot()).
   */
  get inert(): boolean {
    return this.attrMap.has("inert");
  }
  set inert(value: boolean) {
    setAttributeFlag(this, "inert", value);
    // Focus never stays inside a subtree that just went inert: it goes nowhere, as in a browser.
    if (value && focusState.el !== null && (focusState.el === this || this.contains(focusState.el))) setFocus(null);
  }
  /** The nearest element from here outward that is inert, by the attribute or interactivity, or null. */
  inertRoot(): Element | null {
    let n: Element | null = this;
    while (n !== null) {
      if (n.inert || n.sv[P.P_INTERACTIVITY] === P.IA_INERT) return n;
      n = n.parentElement;
    }
    return null;
  }

  /**
   * The `popover` attribute: "auto" (what an empty value means), "manual", or null when the
   * element isn't a popover. A value that names neither is "manual", as a browser maps it.
   */
  get popover(): string | null {
    const v = this.attrMap.get("popover");
    if (v === undefined) return null;
    const word = v.trim().toLowerCase();
    return word === "" || word === "auto" ? "auto" : "manual";
  }
  set popover(value: string | null) {
    if (value === null) this.removeAttribute("popover");
    else this.setAttribute("popover", value === "auto" ? "" : value);
  }
  /** The element `popovertarget` names, or null. */
  get popoverTargetElement(): Element | null {
    const id = this.getAttribute("popovertarget");
    return id === null ? null : document.getElementById(id);
  }
  set popoverTargetElement(value: Element | null) {
    if (value === null) {
      this.removeAttribute("popovertarget");
      return;
    }
    // A browser gives the element an id when it has none, so the attribute can name it.
    if (value.id === "") value.id = "native-popover-target-" + String(nextPopoverTarget++);
    this.setAttribute("popovertarget", value.id);
  }
  /** What activating the invoker does to its popover: "toggle" (the default), "show" or "hide". */
  get popoverTargetAction(): string {
    const v = this.getAttribute("popovertargetaction");
    const word = v === null ? "" : v.trim().toLowerCase();
    return word === "show" || word === "hide" ? word : "toggle";
  }
  set popoverTargetAction(value: string) {
    this.setAttribute("popovertargetaction", value);
  }

  /**
   * Shows the popover: it draws from now on, and an auto popover closes the auto popovers that
   * were open. There is no top layer here, so it draws where it sits in the tree.
   */
  showPopover(): void {
    const kind = this.popover;
    if (kind === null) throw new Error("NotSupportedError: showPopover() needs a popover attribute");
    if (!this.isConnected) throw new Error("InvalidStateError: the element is not in the document");
    if ((this.state & P.S_POPOVER_OPEN) !== 0) throw new Error("InvalidStateError: the popover is already showing");
    const before = new ToggleEvent("beforetoggle", { cancelable: true, oldState: "closed", newState: "open" });
    if (!dispatch(trusted(before), this)) return;
    if (kind === "auto") {
      for (let i = openPopovers.length - 1; i >= 0; i--) {
        if (openPopovers[i].popover === "auto") hidePopoverNow(openPopovers[i]);
      }
    }
    this.state |= P.S_POPOVER_OPEN;
    openPopovers.push(this);
    openPopoverCount++;
    addToTopLayer(this);
    invalidateStyle();
    invalidateLayout();
    dispatch(trusted(new ToggleEvent("toggle", { oldState: "closed", newState: "open" })), this);
  }
  /** Hides the popover, firing beforetoggle (cancelable) and toggle. */
  hidePopover(): void {
    if (this.popover === null) throw new Error("NotSupportedError: hidePopover() needs a popover attribute");
    if ((this.state & P.S_POPOVER_OPEN) === 0) throw new Error("InvalidStateError: the popover is not showing");
    hidePopoverNow(this);
  }
  /** Toggles the popover, or shows/hides it when `force` says which. Null when it isn't one. */
  togglePopover(force?: boolean): boolean | null {
    const showing = (this.state & P.S_POPOVER_OPEN) !== 0;
    if (this.popover === null) return null;
    const want = force === undefined ? !showing : force;
    if (want === showing) return showing;
    if (want) this.showPopover();
    else this.hidePopover();
    return want;
  }

  /** Dispatches a bubbling click event starting at this element, as a browser's click() does. */
  click(): void {
    // A disabled control takes neither a click event nor its default action, as in a browser.
    if (inDisabledFormControl(this)) return;
    if (dispatch(trusted(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })), this)) {
      runClickDefault(this);
    }
  }

  /**
   * Whether the element can take focus at all: a form control, a link with an href, or anything
   * carrying tabindex (including -1, which takes focus without joining the tab order).
   */
  get isFocusable(): boolean {
    // Nothing inside an inert subtree takes focus, its own tabindex included.
    if (this.inertRoot() !== null) return false;
    if (this.hasAttribute("tabindex")) return true;
    // An editing host takes focus, and carries a caret, the way a text field does.
    if (isContentEditableElement(this)) return true;
    const tag = this.localName;
    if (tag === "a" || tag === "area") return this.hasAttribute("href") && !this.hasAttribute("disabled");
    if (tag === "input" || tag === "select" || tag === "textarea" || tag === "button" ||
      tag === "iframe" || tag === "summary") return !this.hasAttribute("disabled");
    return false;
  }

  /** Whether Tab reaches the element: focusable, enabled and with a non-negative tab index. */
  get isTabbable(): boolean {
    return this.isFocusable && !this.hasAttribute("disabled") && this.tabIndex >= 0;
  }

  /**
   * The element's place in the tab order. The tabindex attribute decides it; without one a
   * control is in the order (0) and other elements are not (-1), as in a browser.
   */
  get tabIndex(): number {
    const attr = this.getAttribute("tabindex");
    if (attr !== null) {
      const n = Number(attr);
      return attr.trim() === "" || n !== n ? -1 : Math.trunc(n);
    }
    const tag = this.localName;
    if (tag === "a" || tag === "area") return this.hasAttribute("href") ? 0 : -1;
    if (tag === "input" || tag === "select" || tag === "textarea" || tag === "button" ||
      tag === "iframe" || tag === "summary") return 0;
    // An editing host is in the tab order; an element merely inside one is not.
    if (this.getAttribute("contenteditable") !== null && isContentEditableElement(this)) return 0;
    return -1;
  }
  set tabIndex(value: number) {
    this.setAttribute("tabindex", String(Math.trunc(value)));
  }

  /**
   * Moves focus here, when the element can take it. The options are accepted as the DOM has
   * them; focus never scrolls the page here, so preventScroll changes nothing. Without an
   * explicit focusVisible, the element decides, as a browser does: a text field always shows
   * the ring, and anything else shows it when the last interaction came from the keyboard.
   */
  focus(options?: { preventScroll?: boolean; focusVisible?: boolean }): void {
    if (this.isFocusable) setFocus(this, options?.focusVisible);
  }
  blur(): void {
    if (focusState.el === this) setFocus(null);
  }

  /** Whether the element matches the selector, with :scope being the element itself. */
  matches(selector: string): boolean {
    const sels = parseSelectorArg(selector, "matches", "Element");
    return matchesAny(this, sels, this);
  }
  /** The nearest ancestor-or-self the selector matches, with :scope being this element. */
  closest<T extends Element = Element>(selector: string): T | null {
    const sels = parseSelectorArg(selector, "closest", "Element");
    let e: Element | null = this;
    while (e !== null) {
      if (matchesAny(e, sels, this)) return e as T;
      e = e.parentElement;
    }
    return null;
  }
  /** The first descendant the selector matches; :scope means this element, as the search's root. */
  querySelector<T extends Element = Element>(selector: string): T | null {
    const sels = parseSelectorArg(selector, "querySelector", "Element");
    return firstMatch(this, sels, this) as T | null;
  }
  /** Every descendant the selector matches, in tree order; :scope means this element. */
  querySelectorAll<T extends Element = Element>(selector: string): T[] {
    const sels = parseSelectorArg(selector, "querySelectorAll", "Element");
    const out: Element[] = [];
    collectMatches(this, sels, this, out);
    return out as T[];
  }
  /** The descendants with this tag name, or every descendant for "*". The element itself is not
   *  in its own list, as in a browser. */
  getElementsByTagName<T extends Element = Element>(name: string): HTMLCollectionOf<T> {
    return new HTMLCollection(this, COLL_TAG, name.toLowerCase());
  }
  /** The descendants carrying every one of the space-separated class names. */
  getElementsByClassName<T extends Element = Element>(names: string): HTMLCollectionOf<T> {
    return new HTMLCollection(this, COLL_CLASS, names);
  }
  /** The descendants in the namespace and with the local name; "*" is a wildcard for either. */
  getElementsByTagNameNS(namespace: string, localName: string): Element[] {
    const out: Element[] = [];
    for (const c of this.kids) collectByTag(c, namespace, localName, out);
    return out;
  }

  /**
   * Takes the pointer's capture: its events go to this element whatever it is over, until the
   * button lifts or releasePointerCapture() gives it up. Only a pressed pointer can be captured,
   * so this throws for a pointer id the host isn't holding down.
   */
  setPointerCapture(pointerId: number): void {
    if (activePointers.indexOf(pointerId) < 0) {
      throw new Error("NotFoundError: Failed to execute 'setPointerCapture' on 'Element': "
        + "No active pointer with the given id is found.");
    }
    capturedElement = this;
    capturedPointerId = pointerId;
    dispatch(trusted(new PointerEvent("gotpointercapture", { bubbles: true, composed: true })), this);
  }

  /** Gives up a capture this element holds; one held by another element isn't touched. */
  releasePointerCapture(pointerId: number): void {
    if (capturedElement !== this || capturedPointerId !== pointerId) return;
    capturedElement = null;
    capturedPointerId = -1;
    dispatch(trusted(new PointerEvent("lostpointercapture", { bubbles: true, composed: true })), this);
  }

  hasPointerCapture(pointerId: number): boolean {
    return capturedElement === this && capturedPointerId === pointerId;
  }

  // Shadow trees live on Element, as the DOM puts them: a page's getElementById hands back an
  // Element, and attachShadow has to be there.
  /** The shadow tree this element hosts, when one has been attached. */
  private shadowRootEl: ShadowRoot | null = null;

  /**
   * Attaches a shadow tree. Its children are the element's shadow content; the element itself can
   * only host one, so a second call throws NotSupportedError, as a browser's does.
   */
  attachShadow(init: { mode: string; delegatesFocus?: boolean; slotAssignment?: string; clonable?: boolean; serializable?: boolean }): ShadowRoot {
    if (init.mode !== "open" && init.mode !== "closed") {
      throw new TypeError("TypeError: Failed to execute 'attachShadow' on 'Element': The provided value '" + init.mode + "' is not a valid enum value of type ShadowRootMode.");
    }
    const wanted = init.mode === "closed" ? "closed" : "open";
    if (this.shadowRootEl !== null) {
      // A host that already has a root returns it when the mode matches — the root a declarative
      // template made included — and refuses a different mode, as the DOM says.
      if (this.shadowRootEl.mode !== wanted) {
        throw new Error("NotSupportedError: Failed to execute 'attachShadow' on 'Element': The mode of the existing shadow root does not match the mode of the provided ShadowRootInit.");
      }
      return this.shadowRootEl;
    }
    const assignment = init.slotAssignment === undefined ? "named" : init.slotAssignment;
    if (assignment !== "named" && assignment !== "manual") {
      throw new TypeError("TypeError: Failed to execute 'attachShadow' on 'Element': The provided value '" + assignment + "' is not a valid enum value of type SlotAssignmentMode.");
    }
    const root = new ShadowRoot(this, wanted, init.delegatesFocus === true, assignment,
      init.clonable === true, init.serializable === true);
    this.shadowRootEl = root;
    shadowTrees++;
    return root;
  }

  /** The slot name this element asks its host's shadow tree for. */
  get slot(): string {
    const v = this.getAttribute("slot");
    return v === null ? "" : v;
  }
  set slot(value: string) {
    this.setAttribute("slot", value);
  }

  /** The shadow tree this element hosts, whatever its mode: layout renders its children. */
  shadowTree(): ShadowRoot | null {
    return this.shadowRootEl;
  }

  /** The shadow root a script can reach: only an open one, as in a browser. */
  get shadowRoot(): ShadowRoot | null {
    return this.shadowRootEl !== null && this.shadowRootEl.mode === "open" ? this.shadowRootEl : null;
  }
}

/** Whether an element drags with no `draggable` attribute: an image, or a link with an href. */
function dragsByDefault(el: Element): boolean {
  if (el instanceof HTMLImageElement) return true;
  return el instanceof HTMLAnchorElement && el.hasAttribute("href");
}

/** An HTML element. Elements created by document.createElement are all of this class. */
/** What an SVG <path> is typed as. The runtime builds SVG nodes as ordinary elements, and the
 *  geometry methods live on Element; this names the type a path's ref has, and merges with the
 *  empty interface a framework's global declarations already make for it. */
export interface SVGPathElement extends HTMLElement {}

export class HTMLElement extends Element {
  get [Symbol.toStringTag](): string { return "HTMLElement"; }
  /**
   * An element takes no arguments, as a browser's HTMLElement does, so a class a script defines
   * reads `constructor() { super(); }` and the registry gives the element its tag afterwards.
   */
  constructor() {
    super();
  }

  /**
   * Sets what an element is: the tag it stands for, its id, the text it holds, and the rules and
   * state the build gave it. The runtime's factory calls this after constructing an element of the
   * class for its tag, which is how a constructor that takes nothing still makes a full element.
   */
  initEl(tag: string, id: string, text: string, rules: readonly number[], states: number, inline: boolean): void {
    this.initNode(tag, text, rules, states, inline);
    this.idValue = id;
    // The build sets the id through its slot rather than setAttribute, but the attribute is one
    // the element carries: `attributes` lists it (first, as markup usually writes it).
    if (id !== "") this.recordSlotAttribute("id");
  }

  /**
   * The `draggable` attribute: whether a press on the element starts a drag rather than a
   * selection. With no attribute it is a link or an image that drags, as HTML's auto value says;
   * `draggable="true"` makes anything draggable and `"false"` takes it back.
   */
  get draggable(): boolean {
    const value = this.getAttribute("draggable");
    if (value === null) return dragsByDefault(this);
    return value.trim().toLowerCase() === "true";
  }
  set draggable(value: boolean) {
    this.setAttribute("draggable", value ? "true" : "false");
  }

  /** The `dir` attribute: the element's text direction, or "auto" to take it from its text. */
  get dir(): string {
    return this.getAttribute("dir") ?? "";
  }
  set dir(value: string) {
    this.setAttribute("dir", String(value));
  }

  /** The `lang` attribute: the element's language, which :lang() reads through inheritance. */
  get lang(): string {
    return this.getAttribute("lang") ?? "";
  }
  set lang(value: string) {
    this.setAttribute("lang", String(value));
  }

  /**
   * The `translate` attribute as a boolean. An element that says `no` (any case) is not
   * translated; one that says anything else, including a value the attribute doesn't define, is.
   * An element with no attribute of its own takes its parent's answer, and a document's own is
   * "yes".
   */
  get translate(): boolean {
    const value = this.getAttribute("translate");
    if (value !== null) return value.toLowerCase() !== "no";
    const parent = this.parentElement;
    if (parent === null || !(parent instanceof HTMLElement)) return true;
    return parent.translate;
  }
  set translate(value: boolean) {
    this.setAttribute("translate", value ? "yes" : "no");
  }

  /** The internals attachInternals() made, if it has been called. */
  internalsObj: ElementInternals | null = null;

  /**
   * The internals a form-associated custom element uses to say what it submits and which
   * constraints it fails. Only an element whose tag has a custom-element definition may have them,
   * and only once, as a browser's attachInternals() demands.
   */
  attachInternals(): ElementInternals {
    // The tag is set after a class's constructor returns, so a constructor that attaches internals
    // asks about the name it is being built for.
    const tag = this.localName !== "" ? this.localName : constructingTag;
    if (tag === "" || customConstructor(tag) === null) {
      throw new Error("NotSupportedError: Failed to execute 'attachInternals' on 'HTMLElement': Unable to attach ElementInternals to non-custom elements.");
    }
    if (this.internalsObj !== null) {
      throw new Error("NotSupportedError: Failed to execute 'attachInternals' on 'HTMLElement': ElementInternals is already attached.");
    }
    const made = new ElementInternals(this);
    this.internalsObj = made;
    return made;
  }







  /**
   * Whether the element's content is editable: the nearest `contenteditable` ancestor that isn't
   * `false` makes it so, and a form control ignores the attribute, as in HTML.
   */
  get isContentEditable(): boolean {
    return editingHostFor(this) !== null;
  }

  /** The contenteditable attribute as a property: "true", "false", "plaintext-only" or "inherit". */
  get contentEditable(): string {
    const value = this.getAttribute("contenteditable");
    if (value === null) return "inherit";
    const lower = value.trim().toLowerCase();
    if (lower === "" || lower === "true") return "true";
    if (lower === "false") return "false";
    if (lower === "plaintext-only") return "plaintext-only";
    return "inherit";
  }
  set contentEditable(value: string) {
    this.setAttribute("contenteditable", String(value));
  }
}

export function isContentEditableElement(el: Element): boolean {
  return editingHostFor(el) !== null;
}

/**
 * The editing host for a node: the nearest ancestor (itself included) whose contenteditable
 * attribute makes it editable. `false` ends the search, as an ancestor's `false` unedits the subtree;
 * a form control is never an editing host.
 */
export function editingHostFor(node: Node | null | undefined): Element | null {
  let n: Node | null | undefined = node;
  while (n !== null && n !== undefined) {
    if (n.nodeType === 1) {
      const el = n as Element;
      if (isFormControlName(el.localName)) return null;
      if (el.hasAttribute("contenteditable")) {
        const value = (el.getAttribute("contenteditable") ?? "").trim().toLowerCase();
        if (value === "false") return null;
        if (value === "" || value === "true" || value === "plaintext-only") return el;
        // "inherit" and values this build doesn't know fall through to the parent.
      }
    }
    n = n.parentNode;
  }
  return null;
}

function isFormControlName(name: string): boolean {
  return name === "input" || name === "select" || name === "textarea" || name === "button";
}

// ---------------------------------------------------------------------------
// <img>

/**
 * An image element. The host decodes the file when `src` is set (a URL resolves against the
 * page's own directory, as it would on the web), and the load lands on the next turn of the
 * loop, so a listener added before `src` sees it.
 */

/** A markup <img> takes its source from the src attribute the build set, and starts loading. */
export function adoptImageSource(el: Node): void {
  if (el instanceof HTMLImageElement) el.adoptSource();
}

/** A markup <audio> or <video> takes its source from the src attribute and starts loading. */
export function adoptMediaSource(el: Node): void {
  if (el instanceof HTMLMediaElement) el.adoptSource();
}

/**
 * Whether the box scrolls its contents right to left: its start edge is the right, so scrollLeft
 * reads 0 there and runs down to minus what the box can scroll. A horizontal box's horizontal
 * axis is its inline axis, which `direction` turns; a vertical box's is its block axis, which the
 * writing mode turns.
 */
export function rtlScrollsX(el: Element): boolean {
  const wm = el.sv[P.P_WRITING_MODE];
  if (wm === P.WM_VERTICAL_RL || wm === P.WM_SIDEWAYS_RL) return true;
  return el.sv[P.P_DIRECTION] === P.DIR_RTL && wm === P.WM_HORIZONTAL_TB;
}

/**
 * Whether the box scrolls its contents bottom to top: in a vertical writing mode the inline axis
 * runs down the page, and `direction: rtl` turns it, so scrollTop reads 0 at the bottom and runs
 * down to minus what the box can scroll.
 */
export function rtlScrollsY(el: Element): boolean {
  return el.sv[P.P_DIRECTION] === P.DIR_RTL && el.sv[P.P_WRITING_MODE] !== P.WM_HORIZONTAL_TB;
}

/** The left-based offset a script's scrollLeft names on this box. */
function scrollXOf(el: Element, dom: number): number {
  return rtlScrollsX(el) ? dom + (el.scrollWidth - el.clientWidth) : dom;
}

/** A left-based offset as the scrollLeft a script reads back. */
function domScrollXOf(el: Element, x: number): number {
  return rtlScrollsX(el) ? x - (el.scrollWidth - el.clientWidth) : x;
}

/** The top-based offset a script's scrollTop names on this box. */
function scrollYOf(el: Element, dom: number): number {
  return rtlScrollsY(el) ? dom + (el.scrollHeight - el.clientHeight) : dom;
}

/** A top-based offset as the scrollTop a script reads back. */
function domScrollYOf(el: Element, y: number): number {
  return rtlScrollsY(el) ? y - (el.scrollHeight - el.clientHeight) : y;
}

/** The Image() constructor: an <img> whose size attributes the arguments set. */
export class HTMLImageElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLImageElement"; }
  /** The URL as written; "" until src is set. */
  private source = "";
  /** The host's id for the decoded image, or -1 before a load or after one that failed. */
  private decoded = -1;
  /** True while a load is waiting for its pixels, which is what `complete` reports. */
  private loading = false;
  /** Counts the loads started: a load whose source was replaced has nothing to report. */
  private loadSerial = 0;

  /** The alternative text: the `alt` attribute, "" when it has none, as a browser reads it. */
  get alt(): string {
    const value = this.getAttribute("alt");
    return value === null ? "" : value;
  }
  set alt(value: string) {
    this.setAttribute("alt", String(value));
  }

  /** A hint to the renderer about when to decode; the host decodes off the paint thread anyway. */
  get decoding(): string {
    const value = this.getAttribute("decoding");
    return value === null ? "auto" : value;
  }
  set decoding(value: string) {
    this.setAttribute("decoding", String(value));
  }

  /**
   * Resolves when the image's pixels are ready to paint, as a browser's decode() does, and rejects
   * with an EncodingError when they can't be made, or an InvalidStateError when there is no source.
   */
  decode(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.source === "") {
        reject(new Error("InvalidStateError: the image element has no src"));
        return;
      }
      const path = resolveImageSource(this.source);
      const id = path === "" ? -1 : imageId(path, true);
      whenImageReady(id, (ok: boolean) => {
        if (ok && id >= 0) resolve();
        else reject(new Error("EncodingError: the image could not be decoded"));
      });
    });
  }

  constructor(id: string, rules: readonly number[], states: number) {
    super();
    this.initEl("img", id, "", rules, states, true);
  }

  protected makeClone(): Element {
    return new HTMLImageElement(this.id, [], 0);
  }

  get src(): string {
    return this.source;
  }
  set src(value: string) {
    this.source = value;
    this.setAttribute("src", value);
    this.startLoad();
  }

  /** A markup <img>'s src is its source: takes the attribute the build set and starts the load. */
  adoptSource(): void {
    if (this.source !== "") return;
    const src = this.getAttribute("src");
    if (src === null || src === "") return;
    this.source = src;
    this.startLoad();
  }

  /** A browser's complete: no source, or the load has finished (or failed). */
  get complete(): boolean {
    return this.source === "" || (!this.loading && this.decoded >= 0);
  }

  get naturalWidth(): number {
    return this.decoded < 0 ? 0 : imageSizeById(this.decoded)[0];
  }
  get naturalHeight(): number {
    return this.decoded < 0 ? 0 : imageSizeById(this.decoded)[1];
  }

  /** The width attribute, or the intrinsic width when it has none: what renderers upload with. */
  get width(): number {
    const attr = this.attrMap.get("width");
    if (attr !== undefined && attr !== "") {
      const n = Number(attr);
      if (n === n) return n;
    }
    return this.naturalWidth;
  }
  set width(value: number) {
    this.setAttribute("width", String(Math.max(0, Math.floor(value))));
  }
  get height(): number {
    const attr = this.attrMap.get("height");
    if (attr !== undefined && attr !== "") {
      const n = Number(attr);
      if (n === n) return n;
    }
    return this.naturalHeight;
  }
  set height(value: number) {
    this.setAttribute("height", String(Math.max(0, Math.floor(value))));
  }

  /** The host's id for the decoded image, or -1: what a WebGL texture upload reads. */
  decodedImageId(): number {
    return this.decoded;
  }

  /**
   * Starts the host's decode of the source, the same one a markup <img> uses, and fires load (or
   * error) once its pixels are ready: a browser paints an image only when it has decoded it.
   */
  private startLoad(): void {
    if (this.source === "") return;
    const path = resolveImageSource(this.source);
    const id = path === "" ? -1 : imageId(path, true);
    const serial = ++this.loadSerial;
    this.loading = true;
    // A host that decoded the file as it answered has the pixels now, so the element reports them
    // at once: a WebGL texture uploaded from it in this same turn reads the picture rather than
    // the blank an image with no data leaves. The load itself still lands a turn later, as a
    // browser's does, so a listener added after the src still sees it.
    const ready = path === "" ? -1 : decodedImageNow(path);
    if (ready >= 0) {
      this.decoded = ready;
      this.imagePath = path;
      this.lOwnChanged = true;
      invalidateLayout(this);
    }
    whenImageReady(id, (ok: boolean) => {
      // A later src replaced this load, so this one never lands.
      if (serial !== this.loadSerial) return;
      this.loading = false;
      this.decoded = ok && id >= 0 ? id : -1;
      if (this.decoded >= 0) {
        // Paint and layout find the decoded image by the element's file, as a markup <img> does.
        this.imagePath = path;
        this.lOwnChanged = true;
        invalidateLayout(this);
      }
      this.dispatchEvent(new Event(this.decoded >= 0 ? "load" : "error"));
    });
  }
}

export class Image extends HTMLImageElement {
  get [Symbol.toStringTag](): string { return "Image"; }
  constructor(width?: number, height?: number) {
    super("", [], 0);
    if (width !== undefined && width > 0) this.width = width;
    if (height !== undefined && height > 0) this.height = height;
  }
}

/** Closes every other open details element that shares `el`'s name. */
function closeSameNameDetails(el: HTMLDetailsElement): void {
  const name = el.getAttribute("name");
  if (name === null || name === "" || !el.isConnected) return;
  const all: Element[] = [];
  collectElements(document.documentElement, all);
  for (const e of all) {
    if (e === el || !(e instanceof HTMLDetailsElement) || !e.open) continue;
    if (e.getAttribute("name") === name) e.setOpenState(false);
  }
}

/**
 * A group of details elements with one name keeps a single member open. When a subtree holding
 * open named details is inserted, the first in tree order keeps its open attribute and the
 * later ones close, as the insertion steps say.
 */
export function noteDetailsInserted(node: Node): void {
  const details: HTMLDetailsElement[] = [];
  collectDetails(node, details);
  if (details.length === 0) return;
  const all: Element[] = [];
  collectElements(document.documentElement, all);
  const kept = new Map<string, HTMLDetailsElement>();
  for (const e of all) {
    if (!(e instanceof HTMLDetailsElement) || !e.open) continue;
    const name = e.getAttribute("name");
    if (name === null || name === "") continue;
    const first = kept.get(name);
    if (first === undefined) kept.set(name, e);
    else e.setOpenState(false);
  }
}

/** The details elements at or under `node`, in tree order. */
function collectDetails(node: Node, out: HTMLDetailsElement[]): void {
  if (node.nodeType === 1 && node instanceof HTMLDetailsElement) out.push(node);
  for (const c of node.kids) collectDetails(c, out);
}

/** The summary a details element heads itself with: its first summary child, or null. */
function firstSummaryChild(details: HTMLElement): HTMLSummaryElement | null {
  for (const c of details.children) if (c instanceof HTMLSummaryElement) return c;
  return null;
}

/** Queues the toggle event a details element's open state change fires. */
function dispatchToggle(el: HTMLElement, newState: string, oldState: string): void {
  Promise.resolve().then(() => dispatch(trusted(new ToggleEvent("toggle", { newState, oldState })), el));
}

/**
 * The element classes. An element made by the compiler, by createElement, by parsing markup or
 * by cloning is an instance of the class its tag names, so `instanceof` and the members each
 * class has work as they do in a browser. A class whose element has no members of its own is
 * still a class of its own: it says what kind of element this is and nothing more.
 */

/** What a control's validity is: one flag per constraint it can fail. */
export class ValidityState {
  get [Symbol.toStringTag](): string { return "ValidityState"; }
  valueMissing = false;
  typeMismatch = false;
  patternMismatch = false;
  tooLong = false;
  tooShort = false;
  rangeUnderflow = false;
  rangeOverflow = false;
  stepMismatch = false;
  badInput = false;
  customError = false;

  /** True when no constraint failed. */
  get valid(): boolean {
    return !(this.valueMissing || this.typeMismatch || this.patternMismatch || this.tooLong
      || this.tooShort || this.rangeUnderflow || this.rangeOverflow || this.stepMismatch
      || this.badInput || this.customError);
  }
}

/** The bits of validity a form-associated custom element sets, as setValidity() takes them. */
export interface ValidityStateFlags {
  valueMissing?: boolean;
  typeMismatch?: boolean;
  patternMismatch?: boolean;
  tooLong?: boolean;
  tooShort?: boolean;
  rangeUnderflow?: boolean;
  rangeOverflow?: boolean;
  stepMismatch?: boolean;
  badInput?: boolean;
  customError?: boolean;
}

/**
 * What a form-associated custom element says about itself: the value it submits, the constraints it
 * fails, and the form and labels it belongs to. attachInternals() makes one per element.
 */
export class ElementInternals {
  get [Symbol.toStringTag](): string { return "ElementInternals"; }
  /** The elements the host's aria-actions attribute names. */
  get ariaActionsElements(): Element[] | null { return this.host.ariaActionsElements; }
  set ariaActionsElements(value: Element[] | null) { this.host.ariaActionsElements = value; }
  /** The element these internals belong to. */
  private host: HTMLElement;
  /** The value the element submits, and whether it has one at all. */
  private formValue: string | File | null = null;
  private hasFormValue = false;
  /** The constraints the element set, and the message for them. */
  private flags: ValidityStateFlags = {};
  private message = "";

  constructor(host: HTMLElement) {
    this.host = host;
  }

  /** The value this element submits, for new FormData(form); null leaves it out. */
  get submittedValue(): string | File | null {
    return this.hasFormValue ? this.formValue : null;
  }

  /** The form the element belongs to, which its form attribute or its parent decides. */
  get form(): HTMLFormElement | null {
    return formOwnerFor(this.host);
  }

  /** The labels that name the element. */
  get labels(): HTMLLabelElement[] {
    return labelsFor(this.host);
  }

  /** A custom element takes part in validation unless it is disabled. */
  get willValidate(): boolean {
    return !controlDisabled(this.host);
  }

  /** Sets the value the element submits; null submits no entry at all. */
  setFormValue(value: string | File | null): void {
    this.hasFormValue = value !== null;
    this.formValue = value;
  }

  /** Records the constraints the element fails, with the message a failed check reports. */
  setValidity(flags: ValidityStateFlags = {}, message: string = "", anchor: HTMLElement | null = null): void {
    void anchor;
    this.flags = flags;
    this.message = message;
  }

  get validity(): ValidityState {
    const state = new ValidityState();
    state.valueMissing = this.flags.valueMissing === true;
    state.typeMismatch = this.flags.typeMismatch === true;
    state.patternMismatch = this.flags.patternMismatch === true;
    state.tooLong = this.flags.tooLong === true;
    state.tooShort = this.flags.tooShort === true;
    state.rangeUnderflow = this.flags.rangeUnderflow === true;
    state.rangeOverflow = this.flags.rangeOverflow === true;
    state.stepMismatch = this.flags.stepMismatch === true;
    state.badInput = this.flags.badInput === true;
    state.customError = this.flags.customError === true || this.message !== "";
    return state;
  }

  get validationMessage(): string {
    if (this.validity.valid) return "";
    return this.message === "" ? "Please fill out this field." : this.message;
  }

  checkValidity(): boolean {
    if (this.validity.valid) return true;
    dispatch(trusted(new Event("invalid", { cancelable: true })), this.host);
    return false;
  }

  reportValidity(): boolean {
    return this.checkValidity();
  }
}

/**
 * A blob: an immutable run of bytes with a type. The parts it is built from are strings (UTF-8
 * encoded), buffers or other blobs, read when the blob is made, as a browser copies them. Its
 * bytes are read asynchronously, as a browser's are.
 */
export class Blob {
  get [Symbol.toStringTag](): string { return "Blob"; }
  readonly size: number;
  readonly type: string;
  private data: Uint8Array;

  constructor(parts: any[] = [], options?: { type?: string }) {
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (const part of parts) {
      let bytes: Uint8Array;
      if (typeof part === "string") {
        bytes = new TextEncoder().encode(part);
      } else if (part instanceof Blob) {
        bytes = part.copyBytes();
      } else if (part instanceof ArrayBuffer) {
        const view = new Uint8Array(part);
        bytes = new Uint8Array(view.length);
        for (let i = 0; i < view.length; i++) bytes[i] = view[i];
      } else if (part !== null && part !== undefined && typeof part === "object" && typeof part.byteLength === "number") {
        const view = part as ArrayBufferView;
        const source = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
        bytes = new Uint8Array(source.length);
        for (let i = 0; i < source.length; i++) bytes[i] = source[i];
      } else {
        throw new TypeError("A Blob part must be a string, a buffer or another Blob");
      }
      chunks.push(bytes);
      total += bytes.length;
    }
    const all = new Uint8Array(total);
    let at = 0;
    for (const chunk of chunks) {
      for (let i = 0; i < chunk.length; i++) all[at++] = chunk[i];
    }
    this.data = all;
    this.size = total;
    const wanted = options === undefined || options.type === undefined ? "" : String(options.type);
    // The type is lowercased, and any code point above U+007F makes the whole type empty, as
    // the standard says.
    let clean = "";
    let valid = true;
    for (let i = 0; i < wanted.length; i++) {
      const code = wanted.charCodeAt(i);
      if (code > 0x7f) { valid = false; break; }
      clean += wanted[i];
    }
    this.type = valid ? clean.toLowerCase() : "";
  }

  private copyBytes(): Uint8Array {
    const out = new Uint8Array(this.data.length);
    for (let i = 0; i < this.data.length; i++) out[i] = this.data[i];
    return out;
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    const bytes = this.data;
    const buffer = new ArrayBuffer(bytes.length);
    const view = new Uint8Array(buffer);
    for (let i = 0; i < bytes.length; i++) view[i] = bytes[i];
    return buffer;
  }

  async bytes(): Promise<Uint8Array> {
    return this.copyBytes();
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.data);
  }

  /** A blob over a range of this one's bytes, with the type asked for. */
  slice(start: number = 0, end: number = this.size, contentType: string = ""): Blob {
    const from = blobIndex(start, this.size);
    const to = blobIndex(end, this.size);
    const part = new Uint8Array(to > from ? to - from : 0);
    for (let i = 0; i < part.length; i++) part[i] = this.data[from + i];
    return new Blob([part], { type: contentType });
  }

  /** The bytes as a stream, for a body a reader pulls from. */
  stream(): ReadableStream<Uint8Array> {
    const bytes = this.copyBytes();
    return new ReadableStream<Uint8Array>({
      start(controller: any): void {
        controller.enqueue(bytes);
        controller.close();
      },
    });
  }
}

/** A slice bound as the standard reads it: a whole number, a negative one counting back from
 *  the end, clamped to the blob's own range. */
function blobIndex(value: number, size: number): number {
  const n = Number(value);
  if (Number.isNaN(n)) return 0;
  if (n === Infinity) return size;
  if (n === -Infinity) return 0;
  const i = Math.trunc(n);
  return i < 0 ? Math.max(size + i, 0) : Math.min(i, size);
}

/**
 * One file of a file input, or one a drag from outside the app dropped on it. There is no file
 * picker here, so a script makes its own or a drop hands it one; a dropped file is backed by the
 * file on disk, which `text()` and `arrayBuffer()` read.
 */
export class File {
  get [Symbol.toStringTag](): string { return "File"; }
  readonly name: string;
  readonly size: number;
  readonly type: string;
  readonly lastModified: number;
  /** The path the file's bytes come from, when it came off the disk; "" for a script's own. */
  private readonly source: string;
  constructor(name: string, size: number = 0, type: string = "", lastModified: number = 0, source: string = "") {
    this.name = name;
    this.size = size;
    this.type = type;
    this.lastModified = lastModified;
    this.source = source;
  }

  private bytes(): Uint8Array {
    const out = new Uint8Array(this.source === "" ? 0 : Math.max(0, this.size));
    if (this.source !== "") hostFileRead(this.source, (chunk) => {
      // The host hands the whole file over in one call, inside the call.
      for (let i = 0; i < chunk.length && i < out.length; i++) out[i] = chunk[i];
    });
    return out;
  }

  /** The file's bytes as text, UTF-8 decoded, as a browser's File reads itself. */
  async text(): Promise<string> {
    return new TextDecoder().decode(this.bytes());
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    const bytes = this.bytes();
    const buffer = new ArrayBuffer(bytes.length);
    const view = new Uint8Array(buffer);
    for (let i = 0; i < bytes.length; i++) view[i] = bytes[i];
    return buffer;
  }
}

export type FileList = readonly File[];

/**
 * What a form entry carries: a control's text, or a file a file field holds.
 */
export type FormDataEntryValue = string | File;

/**
 * A form's entries: the name/value pairs a submit would send, in the order the controls appear,
 * with the files a file field holds. A script builds one empty and appends, sets and deletes
 * entries, or builds one from a form to read what it would send.
 */
export class FormData {
  get [Symbol.toStringTag](): string { return "FormData"; }
  /** The entries' names and values, one pair per entry, in the order they were added. */
  private entryNames: string[] = [];
  private entryValues: FormDataEntryValue[] = [];

  /** An empty set of entries, or the entries `form` would submit when it is given. */
  constructor(form?: HTMLFormElement | null) {
    if (form !== undefined && form !== null) collectFormEntries(form, this);
  }

  append(name: string, value: FormDataEntryValue): void {
    this.entryNames.push(String(name));
    this.entryValues.push(value);
  }

  /** Puts `value` where the first entry under `name` is, and drops any others under it. */
  set(name: string, value: FormDataEntryValue): void {
    const key = String(name);
    const first = this.entryNames.indexOf(key);
    if (first < 0) {
      this.append(key, value);
      return;
    }
    this.entryValues[first] = value;
    for (let i = this.entryNames.length - 1; i > first; i--) {
      if (this.entryNames[i] === key) {
        this.entryNames.splice(i, 1);
        this.entryValues.splice(i, 1);
      }
    }
  }

  /** The first value under `name`, or null when there is none. */
  get(name: string): FormDataEntryValue | null {
    const i = this.entryNames.indexOf(String(name));
    return i < 0 ? null : this.entryValues[i];
  }

  /** Every value under `name`, in order. */
  getAll(name: string): FormDataEntryValue[] {
    const key = String(name);
    const out: FormDataEntryValue[] = [];
    for (let i = 0; i < this.entryNames.length; i++) {
      if (this.entryNames[i] === key) out.push(this.entryValues[i]);
    }
    return out;
  }

  has(name: string): boolean {
    return this.entryNames.indexOf(String(name)) >= 0;
  }

  delete(name: string): void {
    const key = String(name);
    for (let i = this.entryNames.length - 1; i >= 0; i--) {
      if (this.entryNames[i] === key) {
        this.entryNames.splice(i, 1);
        this.entryValues.splice(i, 1);
      }
    }
  }

  /** The entries in order, each a [name, value] pair: a browser gives an iterator here. */
  entries(): [string, FormDataEntryValue][] {
    const out: [string, FormDataEntryValue][] = [];
    for (let i = 0; i < this.entryNames.length; i++) out.push([this.entryNames[i], this.entryValues[i]]);
    return out;
  }

  keys(): string[] {
    return this.entryNames.slice();
  }

  values(): FormDataEntryValue[] {
    return this.entryValues.slice();
  }

  forEach(callback: (value: FormDataEntryValue, name: string, form: FormData) => void): void {
    for (let i = 0; i < this.entryNames.length; i++) callback(this.entryValues[i], this.entryNames[i], this);
  }
}

/**
 * Adds the entries `form` would submit: every successful control it owns, in document order — a
 * named control that isn't disabled and isn't a button, a checked box or radio (its value, which
 * is "on" when it has none), a file field's files, a select's chosen options, a field's own value.
 */
function collectFormEntries(form: HTMLFormElement, data: FormData): void {
  for (const node of document.getElementsByTagName("*")) {
    if (!(node instanceof HTMLElement)) continue;
    if (formOwnerFor(node) !== form) continue;
    const name = node.getAttribute("name");
    if (name === null || name === "" || inDisabledFormControl(node)) continue;
    // A form-associated custom element submits what its internals say it does; it isn't a listed
    // element, so it is read here rather than by the control branches below.
    const internals = node.internalsObj;
    if (internals !== null) {
      const value = internals.submittedValue;
      if (value !== null) data.append(name, value);
      continue;
    }
    if (!isListedElement(node)) continue;
    if (node instanceof HTMLInputElement) {
      const type = node.type.toLowerCase();
      if (type === "checkbox" || type === "radio") {
        if (node.checked) data.append(name, node.value);
      } else if (type === "file") {
        for (const file of node.files) data.append(name, file);
      } else if (type !== "submit" && type !== "reset" && type !== "button" && type !== "image") {
        data.append(name, node.value);
      }
    } else if (node instanceof HTMLTextAreaElement) {
      data.append(name, node.value);
    } else if (node instanceof HTMLSelectElement) {
      for (const option of node.options) if (option.selected) data.append(name, option.value);
    }
  }
}

/** A boolean attribute as a property: presence is true, and setting it reflects. */
function attributeFlag(el: Element, name: string): boolean {
  return el.getAttribute(name) !== null;
}
function setAttributeFlag(el: Element, name: string, on: boolean): void {
  if (on) el.setAttribute(name, "");
  else el.removeAttribute(name);
}

/** A number an attribute carries, or `fallback` when it isn't there or isn't a number. */
function numberAttribute(el: Element, name: string, fallback: number): number {
  const v = el.getAttribute(name);
  if (v === null || v === "") return fallback;
  const n = Number(v);
  return isNaN(n) ? fallback : n;
}

/** The elements a form lists and a label can name. */
function isLabelable(el: Element): boolean {
  const n = el.localName;
  return n === "button" || n === "input" || n === "meter" || n === "output"
    || n === "progress" || n === "select" || n === "textarea";
}

/** The elements a form lists, which is the same set plus fieldsets and objects. */
function isListedElement(el: Element): boolean {
  return isLabelable(el) || el.localName === "fieldset" || el.localName === "object";
}

/** The first labelable descendant of `root`, in document order. */
function labelableDescendant(root: Node): HTMLElement | null {
  for (const c of root.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    const e = c as Element;
    if (isLabelable(e)) return e as HTMLElement;
    const deep = labelableDescendant(e);
    if (deep !== null) return deep;
  }
  return null;
}

/** Every element under `root`, in document order. */
function collectElements(root: Node, out: Element[]): void {
  for (const c of root.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    out.push(c as Element);
    collectElements(c, out);
  }
}

/** The form's listed elements, in document order. */
function collectListedElements(root: Node, out: HTMLElement[]): void {
  for (const c of root.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    const e = c as Element;
    if (isListedElement(e)) out.push(e as HTMLElement);
    // A listed element's descendants are listed too: a form's controls inside a fieldset, and a
    // nested fieldset's controls, are all in the collection.
    collectListedElements(e, out);
  }
}

/** The form a control belongs to: the one its form attribute names, or the one around it. */
function formOwnerFor(el: HTMLElement): HTMLFormElement | null {
  const id = el.getAttribute("form");
  if (id !== null && id !== "") {
    const found = document.getElementById(id);
    if (found !== null && found instanceof HTMLFormElement) return found;
  }
  let p = el.parentNode;
  while (p !== null) {
    if (p instanceof HTMLFormElement) return p;
    p = p.parentNode;
  }
  return null;
}

/** The labels that name `el`: the ones around it, and the ones whose for= gives its id. */
function labelsFor(el: HTMLElement): HTMLLabelElement[] {
  const all: Element[] = [];
  collectElements(document.documentElement, all);
  const out: HTMLLabelElement[] = [];
  for (const e of all) {
    if (!(e instanceof HTMLLabelElement)) continue;
    if (e.control === el) out.push(e);
  }
  return out;
}

// ---------------------------------------------------------------------------
// The classes

export class HTMLAnchorElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLAnchorElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("a", id, text, rules, states, inline);
  }
  get href(): string {
    const v = this.getAttribute("href");
    return v === null ? "" : v;
  }
  set href(value: string) {
    this.setAttribute("href", value);
  }
  get target(): string {
    const v = this.getAttribute("target");
    return v === null ? "" : v;
  }
  set target(value: string) {
    this.setAttribute("target", value);
  }
  get rel(): string {
    const v = this.getAttribute("rel");
    return v === null ? "" : v;
  }
  set rel(value: string) {
    this.setAttribute("rel", value);
  }
  get download(): string {
    const v = this.getAttribute("download");
    return v === null ? "" : v;
  }
  set download(value: string) {
    this.setAttribute("download", value);
  }
  get text(): string {
    return this.textContent;
  }
  set text(value: string) {
    this.textContent = value;
  }
}

export class HTMLAreaElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLAreaElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("area", id, text, rules, states, inline);
  }
  get href(): string {
    const v = this.getAttribute("href");
    return v === null ? "" : v;
  }
  set href(value: string) {
    this.setAttribute("href", value);
  }
}

export class HTMLBRElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLBRElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("br", id, text, rules, states, inline);
  }
}

export class HTMLBaseElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLBaseElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("base", id, text, rules, states, inline);
  }
  get href(): string {
    const v = this.getAttribute("href");
    return v === null ? "" : v;
  }
  set href(value: string) {
    this.setAttribute("href", value);
  }
}

export class HTMLBodyElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLBodyElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("body", id, text, rules, states, inline);
  }
}

export class HTMLButtonElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLButtonElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("button", id, text, rules, states, inline);
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  get labels(): HTMLLabelElement[] {
    return labelsFor(this);
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get value(): string {
    const v = this.getAttribute("value");
    return v === null ? "" : v;
  }
  set value(value: string) {
    this.setAttribute("value", value);
  }
  /** "submit" unless the type attribute says otherwise. */
  get type(): string {
    const v = this.getAttribute("type");
    if (v === null) return "submit";
    const t = v.toLowerCase();
    return t === "reset" || t === "button" ? t : "submit";
  }
  set type(value: string) {
    this.setAttribute("type", value);
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
}

export class HTMLDataListElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDataListElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("datalist", id, text, rules, states, inline);
  }
  /** The options the list offers, in document order. */
  get options(): HTMLOptionElement[] {
    const out: HTMLOptionElement[] = [];
    const all: Element[] = [];
    collectElements(this, all);
    for (const e of all) if (e instanceof HTMLOptionElement) out.push(e);
    return out;
  }
}

export class HTMLDetailsElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDetailsElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("details", id, text, rules, states, inline);
  }
  get open(): boolean {
    return attributeFlag(this, "open");
  }
  set open(value: boolean) {
    this.setOpenState(value);
  }
  /** Changes the open attribute and queues the toggle event the change calls for. */
  setOpenState(next: boolean): void {
    if (attributeFlag(this, "open") === next) return;
    if (next) super.setAttribute("open", "");
    else super.removeAttribute("open");
    if (next) closeSameNameDetails(this);
    dispatchToggle(this, next ? "open" : "closed", next ? "closed" : "open");
  }
  setAttribute(name: string, value: any): void {
    const key = String(name).toLowerCase();
    if (key === "open") {
      this.setOpenState(true);
      return;
    }
    super.setAttribute(name, value);
    if (key === "name" && this.open) closeSameNameDetails(this);
  }
  removeAttribute(name: string): void {
    if (String(name).toLowerCase() === "open") {
      this.setOpenState(false);
      return;
    }
    super.removeAttribute(name);
  }
}

export class HTMLDialogElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDialogElement"; }
  /** What close() was given, which a script reads after the dialog closes. */
  returnValue = "";
  private modal = false;

  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("dialog", id, text, rules, states, inline);
  }
  get open(): boolean {
    return attributeFlag(this, "open");
  }
  set open(value: boolean) {
    setAttributeFlag(this, "open", value);
    if (!value && this.modal) {
      this.modal = false;
      removeFromTopLayer(this);
    }
  }
  /** Whether showModal() opened it, which puts it on top with a ::backdrop under it. */
  get isModal(): boolean {
    return this.modal;
  }
  /**
   * Shows the dialog non-modally. An already-open non-modal dialog stays as it is; a modal one
   * can't become non-modal without closing first.
   */
  show(): void {
    if (this.modal) {
      throw new Error("InvalidStateError: Failed to execute 'show' on 'HTMLDialogElement': The dialog is already open as a modal dialog.");
    }
    if (this.open) return;
    this.open = true;
  }
  /** Shows the dialog as a modal dialog, on top of the page with a ::backdrop under it. */
  showModal(): void {
    if (this.open) {
      // A dialog already showing modally stays as it is; one showing non-modally can't become modal.
      if (this.modal) return;
      throw new Error("InvalidStateError: Failed to execute 'showModal' on 'HTMLDialogElement': The dialog is already open.");
    }
    if (!this.isConnected) {
      throw new Error("InvalidStateError: Failed to execute 'showModal' on 'HTMLDialogElement': The dialog is not in a document.");
    }
    this.open = true;
    this.modal = true;
    addToTopLayer(this);
  }
  /**
   * Closes the dialog. A close event is queued as a task, so a handler never runs inside the call
   * that closed the dialog.
   */
  close(returnValue?: string): void {
    if (returnValue !== undefined) this.returnValue = returnValue;
    if (!this.open) return;
    this.open = false;
    this.modal = false;
    removeFromTopLayer(this);
    Promise.resolve().then(() => dispatch(trusted(new Event("close")), this));
  }
}

export class HTMLDivElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDivElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("div", id, text, rules, states, inline);
  }
}

/** A <data> element, which carries its machine-readable value in the value attribute. */
export class HTMLDataElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDataElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("data", id, text, rules, states, inline);
  }
}

export class HTMLDirectoryElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDirectoryElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("dir", id, text, rules, states, inline);
  }
}

export class HTMLDListElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLDListElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("dl", id, text, rules, states, inline);
  }
}

export class HTMLEmbedElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLEmbedElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("embed", id, text, rules, states, inline);
  }
}

export class HTMLFontElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLFontElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("font", id, text, rules, states, inline);
  }
}

export class HTMLFrameElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLFrameElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("frame", id, text, rules, states, inline);
  }
}

export class HTMLFrameSetElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLFrameSetElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("frameset", id, text, rules, states, inline);
  }
}

export class HTMLHRElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLHRElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("hr", id, text, rules, states, inline);
  }
}

export class HTMLLinkElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLLinkElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("link", id, text, rules, states, inline);
  }
  /** The media condition the linked stylesheet applies in; it reflects the media attribute. */
  get media(): string {
    const v = this.getAttribute("media");
    return v === null ? "" : v;
  }
  set media(value: string) {
    this.setAttribute("media", value);
  }
  /**
   * Whether the linked stylesheet is out of the cascade. It reflects the `disabled` content
   * attribute, and a change reaches the rules the build compiled from the sheet through the
   * style engine, since a <link> has no sheet object of its own.
   */
  get disabled(): boolean {
    return this.hasAttribute("disabled");
  }
  set disabled(value: boolean) {
    if (Boolean(value)) this.setAttribute("disabled", "");
    else this.removeAttribute("disabled");
  }
}

export class HTMLMapElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLMapElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("map", id, text, rules, states, inline);
  }
}

/** A <del> or <ins>: the same interface for both, as a browser has it. */
export class HTMLModElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLModElement"; }
  constructor(tag: string = "del", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
}

export class HTMLObjectElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLObjectElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("object", id, text, rules, states, inline);
  }
}

export class HTMLParamElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLParamElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("param", id, text, rules, states, inline);
  }
}

/** A <q> or <blockquote>. */
export class HTMLQuoteElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLQuoteElement"; }
  constructor(tag: string = "q", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
}

export class HTMLSourceElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLSourceElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("source", id, text, rules, states, inline);
  }
}

export class HTMLTrackElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTrackElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("track", id, text, rules, states, inline);
  }
}

/** A tag this runtime has no interface of its own for. */
export class HTMLUnknownElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLUnknownElement"; }
  constructor(tag: string = "", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
}

export class HTMLFieldSetElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLFieldSetElement"; }
  /** The message setCustomValidity() was given, which a failed check reports. */
  private customMessage = "";
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("fieldset", id, text, rules, states, inline);
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  /** The controls the fieldset holds, in document order. */
  get elements(): HTMLElement[] {
    const out: HTMLElement[] = [];
    collectListedElements(this, out);
    return out;
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get type(): string {
    return "fieldset";
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
  /** A fieldset is barred from constraint validation itself. */
  get willValidate(): boolean {
    return false;
  }
  /** The constraints the fieldset reports: only the custom error a script set. */
  get validity(): ValidityState {
    const state = new ValidityState();
    state.customError = this.customMessage !== "";
    return state;
  }
  get validationMessage(): string {
    return this.customMessage;
  }
  checkValidity(): boolean {
    const state = this.validity;
    if (state.valid) return true;
    dispatch(trusted(new Event("invalid", { cancelable: true })), this);
    return false;
  }
  reportValidity(): boolean {
    return this.checkValidity();
  }
  setCustomValidity(message: string): void {
    this.customMessage = message;
    noteControlChange(this);
  }
}

export class HTMLFormElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLFormElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("form", id, text, rules, states, inline);
  }
  /** The controls the form holds, in document order. */
  get elements(): HTMLElement[] {
    const out: HTMLElement[] = [];
    collectListedElements(this, out);
    return out;
  }
  get length(): number {
    return this.elements.length;
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get method(): string {
    const v = this.getAttribute("method");
    return v === null ? "get" : v.toLowerCase();
  }
  set method(value: string) {
    this.setAttribute("method", value);
  }
  get action(): string {
    const v = this.getAttribute("action");
    return v === null ? "" : v;
  }
  set action(value: string) {
    this.setAttribute("action", value);
  }
  get noValidate(): boolean {
    return attributeFlag(this, "novalidate");
  }
  set noValidate(value: boolean) {
    setAttributeFlag(this, "novalidate", value);
  }
  /**
   * Fires the form's submit event, after checking its controls unless `skipValidation`. The event
   * is cancelable and names its submitter. There is nowhere to navigate to in a native app, so a
   * submit nobody cancels does nothing more.
   */
  startSubmit(submitter: Element | null, skipValidation: boolean): boolean {
    // A form with method="dialog" closes the dialog it is in, with the submitter's value as the
    // dialog's return value, instead of navigating. Its controls are not validated first.
    if (this.method === "dialog") {
      if (!dispatch(trusted(new SubmitEvent("submit", { bubbles: true, cancelable: true, submitter })), this)) return false;
      let d = this.parentNode;
      while (d !== null && !(d instanceof HTMLDialogElement)) d = d.parentNode;
      if (d instanceof HTMLDialogElement) {
        let value = "";
        if (submitter instanceof HTMLButtonElement || submitter instanceof HTMLInputElement) {
          const v = submitter.getAttribute("value");
          if (v !== null) value = v;
        }
        d.close(value);
      }
      return true;
    }
    if (!skipValidation && !this.noValidate && !this.checkValidity()) return false;
    return dispatch(trusted(new SubmitEvent("submit", { bubbles: true, cancelable: true, submitter })), this);
  }
  /** Fires the submit event without checking the controls, as a browser's submit() does. */
  submit(): void {
    this.startSubmit(null, true);
  }
  /**
   * Submits as a click on `submitter` would: checked first, unless the form is `novalidate`, and
   * the event names the button. Only a submit button of this form may be named.
   */
  requestSubmit(submitter?: HTMLElement | null): void {
    if (submitter !== undefined && submitter !== null) {
      const isSubmitter = (submitter instanceof HTMLButtonElement && submitter.type === "submit")
        || (submitter instanceof HTMLInputElement && isSubmitInput(submitter));
      if (!isSubmitter) throw new Error("TypeError: the submitter isn't a submit button");
      if (formOwnerFor(submitter) !== this) {
        throw new Error("NotFoundError: the submitter isn't a control of this form");
      }
    }
    this.startSubmit(submitter === undefined ? null : submitter, false);
  }
  /** Sends the reset event, then puts every control back to the values it was authored with. */
  reset(): void {
    // A listener can cancel the reset, so the event goes first.
    if (!dispatch(trusted(new Event("reset", { bubbles: true, cancelable: true })), this)) return;
    const controls = this.elements;
    for (const c of controls) {
      if (c instanceof HTMLInputElement) {
        c.value = c.defaultValue;
        c.checked = c.defaultChecked;
      } else if (c instanceof HTMLTextAreaElement) {
        c.value = c.defaultValue;
      } else if (c instanceof HTMLSelectElement) {
        c.selectedIndex = -1;
        const options = c.options;
        for (const o of options) if (o.defaultSelected) o.selected = true;
      }
    }
  }
  checkValidity(): boolean {
    let ok = true;
    const controls = this.elements;
    for (const c of controls) {
      if (!(c instanceof HTMLInputElement) && !(c instanceof HTMLSelectElement)
        && !(c instanceof HTMLTextAreaElement)) continue;
      if (!c.checkValidity()) ok = false;
    }
    return ok;
  }
  reportValidity(): boolean {
    return this.checkValidity();
  }
}

// ---------------------------------------------------------------------------
// Forms: submitting

/** Whether an <input> is a submit button. */
function isSubmitInput(el: HTMLInputElement): boolean {
  const t = el.type.toLowerCase();
  return t === "submit" || t === "image";
}

/** The control a click activates, walking out from what was clicked: a button, or null. */
function controlAt(target: Node): HTMLElement | null {
  let n: Node | null = target;
  while (n !== null) {
    if (n instanceof HTMLButtonElement) return n;
    if (n instanceof HTMLInputElement) {
      const t = n.type.toLowerCase();
      return t === "button" || t === "reset" || t === "submit" || t === "image" ? n : null;
    }
    n = n.parentNode;
  }
  return null;
}

/** The radios a radio is grouped with: the same name, the same form owner and the same tree. */
function radioGroup(el: HTMLInputElement, out: HTMLInputElement[]): void {
  const name = el.name;
  if (name === "") {
    // A radio with no name is a group of its own, so checking it unchecks nothing.
    out.push(el);
    return;
  }
  const all: Element[] = [];
  collectElements(document.documentElement, all);
  const owner = formOwnerFor(el);
  for (const e of all) {
    if (!(e instanceof HTMLInputElement) || controlKind(e.type) !== CONTROL_RADIO) continue;
    if (e.name === name && formOwnerFor(e) === owner) out.push(e);
  }
}

/**
 * Opens the picker over a closed <select>: its options as rows under their groups' labels, the
 * chosen one highlighted. A pick or an arrow key puts the row's option in the field, and "input"
 * then "change" follow, as a user's choice sends them. The runtime draws and drives the panel
 * (see select-popup.ts); a list box is the page's own layout and never comes here.
 */
export function openSelectMenu(el: HTMLSelectElement): void {
  const options = el.options;
  const rows: SelectPopupRow[] = [];
  // Walk the field's children, so a group's label stands over the options it holds. An option
  // outside any group is a row of its own, and a group that is disabled disables its options.
  for (const kid of el.kids) {
    if (kid instanceof HTMLOptGroupElement) {
      const off = kid.disabled;
      if (kid.label !== "") rows.push({ kind: ROW_GROUP, index: -1, label: kid.label, disabled: off });
      for (const g of kid.kids) {
        if (!(g instanceof HTMLOptionElement)) continue;
        rows.push({ kind: ROW_OPTION, index: options.indexOf(g), label: g.label, disabled: off || g.disabled });
      }
    } else if (kid instanceof HTMLOptionElement) {
      rows.push({ kind: ROW_OPTION, index: options.indexOf(kid), label: kid.label, disabled: kid.disabled });
    }
  }
  const accent = el.sv[P.P_ACCENT_COLOR];
  openSelectPopup({
    rows,
    serial: el.serial,
    selected: el.selectedIndex,
    style: {
      font: fontKey(el),
      size: el.sv[P.P_FONT_SIZE],
      lineHeight: lineHeightPx(el),
      letter: letterSpacingPx(el),
      word: wordSpacingPx(el),
      color: el.sv[P.P_COLOR],
      accent: accent < 0 ? -1 : accent,
      dark: (el.state & P.S_SCHEME_DARK) !== 0,
    },
    rect: () => {
      const r = el.getBoundingClientRect();
      return [r.left, r.top, r.width, r.height];
    },
    measure: (text: string) => textWidth(el, text),
    alive: () => el.isConnected && !inDisabledFormControl(el),
    choose: (index: number) => el.selectRow(index, "plain", index),
    // Opening or closing the picker is the field's expanded state moving.
    changed: () => {
      if (axChangeHook !== null) axChangeHook();
    },
  });
}

/**
 * A click's default action on a checkbox or radio: the box ticks, a radio ticks and unchecks the
 * rest of its group, and the "input" and "change" events follow. A disabled control does nothing.
 */
function activateControl(el: HTMLInputElement): void {
  if (controlDisabled(el)) return;
  if (controlKind(el.type) === CONTROL_RADIO) {
    // A radio that is already checked stays checked and sends no event.
    if (el.checked) return;
    const group: HTMLInputElement[] = [];
    radioGroup(el, group);
    for (const other of group) if (other !== el) other.checked = false;
    el.checked = true;
  } else {
    // A half-checked box goes the rest of the way to checked, as a browser does.
    const next = el.indeterminate ? true : !el.checked;
    el.indeterminate = false;
    el.checked = next;
  }
  dispatch(trusted(new Event("input", { bubbles: true })), el);
  dispatch(trusted(new Event("change", { bubbles: true })), el);
}

/**
 * Sets a range field's value, clamped into its range and snapped to its step, and sends the
 * "input" event a user's change sends; `change` adds the "change" event too.
 */
export function setRangeValue(el: HTMLInputElement, value: number, change: boolean): void {
  const spec = rangeSpec(el);
  const text = String(snapRange(value, spec.min, spec.max, spec.step));
  if (text === el.value) return;
  el.value = text;
  dispatch(trusted(new Event("input", { bubbles: true })), el);
  if (change) dispatch(trusted(new Event("change", { bubbles: true })), el);
}

/**
 * The control a click on a label forwards to: the nearest label above the click whose control the
 * click isn't on already. A click on the control itself isn't forwarded again.
 */
function labelTarget(target: Node): HTMLElement | null {
  let n: Node | null = target;
  while (n !== null) {
    if (n instanceof HTMLLabelElement) {
      const control = n.control;
      if (control !== null && !control.contains(target)) return control;
    }
    n = n.parentNode;
  }
  return null;
}

/**
 * Runs a click's default action: a submit button submits its form, and a reset button resets it.
 * A click a listener cancelled never gets here. `user` is true for a click the pointer made, whose
 * gesture opens a select's picker; a click a script dispatches has no gesture, so it can't.
 */
export function runClickDefault(target: Node, user: boolean = false): void {
  // A link with an href navigates, whatever else the click landed in: a target name opens (or
  // reuses) a window, and otherwise the address changes in this one.
  let link: Node | null = target;
  while (link !== null && !(link instanceof HTMLAnchorElement)) link = link.parentNode;
  if (link !== null && link.hasAttribute("href")) {
    followLinkHook(link.getAttribute("href") ?? "", link.getAttribute("target"));
    return;
  }
  // A menuitem's command is its click's default action, as an invoker's: the command event goes
  // out first, then the platform runs the command if it is one of its own.
  let invoker: Node | null = target;
  while (invoker !== null && !(invoker instanceof Element && invoker.localName === "menuitem")) invoker = invoker.parentNode;
  if (invoker !== null && invoker instanceof Element && invoker.hasAttribute("command")) {
    const command = invoker.getAttribute("command") ?? "";
    dispatch(trusted(new CommandEvent("command", { command: command, source: invoker, bubbles: true, composed: true })), invoker);
    runCommandHook(command);
    return;
  }
  // A scroll marker scrolls its group's container to the child it stands for, with that child's
  // start at the start of the scrollport.
  let marker: Node | null = target;
  while (marker !== null && marker.pseudoKind !== P.PE_SCROLL_MARKER) marker = marker.parentNode;
  if (marker !== null && marker.pseudoOrigin !== null) {
    marker.pseudoOrigin.scrollIntoView({ block: "start", inline: "nearest" });
    return;
  }
  // A summary toggles the details it heads, and a details with no summary toggles itself.
  let detail: Node | null = target;
  while (detail !== null) {
    if (detail instanceof HTMLSummaryElement) {
      const owner = detail.parentNode;
      if (owner instanceof HTMLDetailsElement && firstSummaryChild(owner) === detail) {
        owner.open = !owner.open;
        return;
      }
      break;
    }
    if (detail instanceof HTMLDetailsElement) {
      if (firstSummaryChild(detail) === null) {
        detail.open = !detail.open;
        return;
      }
      break;
    }
    detail = detail.parentNode;
  }
  // A label forwards the click to the control it names, which takes its own default action then.
  const labelled = labelTarget(target);
  if (labelled !== null) {
    setFocus(labelled);
    labelled.click();
    return;
  }
  // A select opens its menu, and the choice is the change a user's pick sends.
  let picker: Node | null = target;
  while (picker !== null) {
    if (picker instanceof HTMLSelectElement) {
      // A list box takes its choice from the row a press lands on; only a closed field opens a
      // picker, and only for a click a user made.
      // A press on a closed field opens its picker, and one on the field while its picker is open
      // closes it, as a user's press outside the panel would.
      if (user && !picker.isListBox && !inDisabledFormControl(picker)) {
        if (selectPopupSerial() === picker.serial) closeSelectPopup();
        else openSelectMenu(picker);
      }
      return;
    }
    if (picker instanceof HTMLInputElement || picker instanceof HTMLButtonElement) break;
    picker = picker.parentNode;
  }
  // A checkbox or radio ticks when it is clicked, in a form or not. A range took its new value
  // when the press landed, so the click has nothing left to do.
  let box: Node | null = target;
  while (box !== null) {
    if (box instanceof HTMLInputElement) {
      const kind = controlKind(box.type);
      if (kind === CONTROL_CHECKBOX || kind === CONTROL_RADIO) {
        activateControl(box);
        return;
      }
      if (kind === CONTROL_RANGE) return;
      break;
    }
    if (box instanceof HTMLButtonElement) break;
    box = box.parentNode;
  }
  const control = controlAt(target);
  if (control === null || inDisabledFormControl(control)) return;
  // A popover invoker toggles its popover, shows it or hides it, and does nothing else.
  const popover = control.popoverTargetElement;
  if (popover !== null && popover.popover !== null) {
    const action = control.popoverTargetAction;
    const open = (popover.state & P.S_POPOVER_OPEN) !== 0;
    if (action === "show") {
      if (!open) popover.showPopover();
    } else if (action === "hide") {
      if (open) popover.hidePopover();
    } else {
      popover.togglePopover();
    }
    return;
  }
  const form = formOwnerFor(control);
  if (form === null) return;
  if (control instanceof HTMLButtonElement) {
    if (control.type === "submit") form.startSubmit(control, false);
    else if (control.type === "reset") form.reset();
    return;
  }
  const input = control as HTMLInputElement;
  const t = input.type.toLowerCase();
  if (t === "submit" || t === "image") form.startSubmit(input, false);
  else if (t === "reset") form.reset();
}

/** The form's default button: the first submit button it lists, in tree order. */
function defaultSubmitButton(form: HTMLFormElement): HTMLElement | null {
  for (const el of form.elements) {
    if (el instanceof HTMLButtonElement && el.type === "submit") return el;
    if (el instanceof HTMLInputElement && isSubmitInput(el)) return el;
  }
  return null;
}

/** An input whose type takes text: one of these blocks a form's implicit submission. */
function blocksImplicitSubmission(el: HTMLInputElement): boolean {
  return textEntryType(el.type.toLowerCase());
}

/**
 * Enter in a single-line text field, which submits the form it is in as HTML's implicit
 * submission does: through the form's default button when it has one, else by the form itself
 * when this is its only field.
 */
export function implicitSubmit(input: HTMLInputElement): void {
  if (!blocksImplicitSubmission(input)) return;
  const form = formOwnerFor(input);
  if (form === null) return;
  const button = defaultSubmitButton(form);
  if (button !== null) {
    if (!attributeFlag(button, "disabled")) form.startSubmit(button, false);
    return;
  }
  let fields = 0;
  for (const el of form.elements) if (el instanceof HTMLInputElement && blocksImplicitSubmission(el)) fields++;
  if (fields > 1) return;
  form.startSubmit(null, false);
}

// ---------------------------------------------------------------------------
// Forms: disabled controls

/**
 * Whether a form control is disabled: its own attribute, or a fieldset around it that is
 * disabled. A control inside a disabled fieldset's first legend is not disabled by it.
 */
function controlDisabled(el: HTMLElement): boolean {
  if (attributeFlag(el, "disabled")) return true;
  let a = el.parentElement;
  while (a !== null) {
    if (a instanceof HTMLFieldSetElement && attributeFlag(a, "disabled") && !inFirstLegend(a, el)) return true;
    a = a.parentElement;
  }
  return false;
}

/** Whether the element is inside the fieldset's first legend, which a disabled fieldset spares. */
function inFirstLegend(fieldset: HTMLElement, el: Element): boolean {
  for (const k of fieldset.children) {
    if (k instanceof HTMLLegendElement) return k.contains(el);
  }
  return false;
}

/**
 * Whether a click on this node is swallowed by a disabled form control: the node is one, or sits
 * inside one. A browser fires no click event for such a click and runs no default action.
 */
export function inDisabledFormControl(node: Node): boolean {
  let n: Node | null = node;
  while (n !== null) {
    if (n instanceof HTMLButtonElement || n instanceof HTMLInputElement
      || n instanceof HTMLSelectElement || n instanceof HTMLTextAreaElement) {
      if (controlDisabled(n)) return true;
    }
    n = n.parentNode;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Forms: the state pseudo-classes
//
// :checked, :disabled, :valid and the rest come from a control's attributes, value and validity
// rather than from the pointer and the keyboard, so no event sets them. They are worked out
// when a rule or a DOM query asks about them, and stored in the same state bits every other
// pseudo-class uses, so one matcher answers all of them.

const FORM_CHECKED = P.S_CHECKED | P.S_INDETERMINATE | P.S_DEFAULT;
const FORM_ENABLED = P.S_DISABLED | P.S_ENABLED;
const FORM_REQUIRED = P.S_REQUIRED | P.S_OPTIONAL;
const FORM_EDIT = P.S_READ_ONLY | P.S_READ_WRITE;
const FORM_VALID = P.S_VALID | P.S_INVALID;
const FORM_RANGE = P.S_IN_RANGE | P.S_OUT_OF_RANGE;

/** An input type a user types into (dates and numbers included). Only these are writable. */
function textEntryType(type: string): boolean {
  return type === "text" || type === "search" || type === "tel" || type === "url" || type === "email"
    || type === "password" || type === "date" || type === "month" || type === "week" || type === "time"
    || type === "datetime-local" || type === "number";
}

/** An input type whose value is a label in a button box rather than text to type into. */
export function buttonInputType(type: string): boolean {
  const t = type.toLowerCase();
  return t === "button" || t === "submit" || t === "reset";
}

// The kinds of control native paints for an <input>. A field of any other type is drawn as a text
// field, which is what a browser does when it has no widget of that type.
export const CONTROL_NONE = 0;
export const CONTROL_CHECKBOX = 1;
export const CONTROL_RADIO = 2;
export const CONTROL_RANGE = 3;
export const CONTROL_COLOR = 4;

/** Which control an <input> of this type is, or CONTROL_NONE when native paints no box for it. */
export function controlKind(type: string): number {
  const t = type.toLowerCase();
  if (t === "checkbox") return CONTROL_CHECKBOX;
  if (t === "radio") return CONTROL_RADIO;
  if (t === "range") return CONTROL_RANGE;
  if (t === "color") return CONTROL_COLOR;
  return CONTROL_NONE;
}

/**
 * The simple colour a colour field's value is written as: "#rrggbb" for the colour the text names,
 * or null when it names none. A colour field takes one of CSS Color 4's colours — a name, a
 * function or a hex — but not `transparent`, which has no simple form, and a system colour stands
 * for the colour it names.
 */
export function simpleColor(text: string): string | null {
  const s = text.trim().toLowerCase();
  const system = SYSTEM_COLOR_NAMES[s];
  if (system !== undefined) {
    const v = systemColorValue(system, false);
    return v === null ? null : hexOfColor(v);
  }
  // `transparent` parses as a colour, but it isn't a simple one.
  if (s === "transparent") return null;
  const packed = parseColor(s);
  return packed === null ? null : hexOfColor(packed);
}

/** A packed colour as the "#rrggbb" text a colour field's value is: the alpha part is dropped. */
export function hexOfColor(c: number): string {
  const h = ((c >>> 8) & 0xffffff).toString(16);
  return "#" + "000000".slice(h.length) + h;
}

/** A range field's range, step and value, as its attributes give them. */
export interface RangeSpec {
  /** The value the field shows: inside the range and a whole number of steps above the minimum. */
  value: number;
  min: number;
  max: number;
  /** The step, or 0 for `step="any"`, where any value in the range is allowed. */
  step: number;
}

export function rangeSpec(el: HTMLInputElement): RangeSpec {
  const min = numberAttribute(el, "min", 0);
  let max = numberAttribute(el, "max", 100);
  if (max < min) max = min;
  const stepAttr = el.getAttribute("step");
  const declared = numberAttribute(el, "step", 1);
  const step = stepAttr !== null && stepAttr.trim().toLowerCase() === "any" ? 0 : declared > 0 ? declared : 1;
  // A range with no value sits in the middle of its range, and one whose value isn't a number sits
  // there too.
  const raw = el.value;
  let v = raw === "" ? (min + max) / 2 : Number(raw);
  if (isNaN(v)) v = (min + max) / 2;
  return { value: snapRange(v, min, max, step), min, max, step };
}

/** Clamps `v` into `min`..`max` and to a whole number of steps above the minimum. */
export function snapRange(v: number, min: number, max: number, step: number): number {
  if (v < min) v = min;
  if (v > max) v = max;
  if (step <= 0) return v;
  const n = min + Math.round((v - min) / step) * step;
  if (n < min) return min;
  if (n > max) return max;
  // A fractional step drifts in binary: 0.1 taken 55 times is not 5.5 exactly. The field's own
  // precision is what matters, so the drift is rounded away.
  return Math.round(n * 1e6) / 1e6;
}

/** The elements the disabled attribute, and so :disabled and :enabled, apply to. */
function supportsDisabled(el: Element): boolean {
  const name = el.localName;
  return name === "button" || name === "input" || name === "select" || name === "textarea"
    || name === "fieldset" || name === "optgroup" || name === "option";
}

/** The elements :required can apply to: `required` means nothing on a button or a hidden field. */
function supportsRequired(el: Element): boolean {
  if (el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement) return true;
  if (!(el instanceof HTMLInputElement)) return false;
  const type = el.type.toLowerCase();
  return type !== "hidden" && type !== "range" && type !== "color" && type !== "submit"
    && type !== "reset" && type !== "button" && type !== "image";
}

/** The elements that take part in constraint validation: those :valid and :invalid can match. */
function validationCandidate(el: Element): boolean {
  if (el instanceof HTMLInputElement || el instanceof HTMLSelectElement
    || el instanceof HTMLTextAreaElement) {
    // A control a fieldset disabled is barred from validation, like a disabled one.
    return el.willValidate && !controlDisabled(el);
  }
  if (el instanceof HTMLButtonElement) return el.type !== "button";
  return false;
}

/** Whether the button is its form's default button, the first submit button it lists. */
function isDefaultButton(el: HTMLElement): boolean {
  const form = formOwnerFor(el);
  return form !== null && defaultSubmitButton(form) === el;
}

function checkedBits(el: Element): number {
  let bits = 0;
  if (el instanceof HTMLInputElement) {
    const type = el.type.toLowerCase();
    if (type === "checkbox" || type === "radio") {
      if (el.checked) bits |= P.S_CHECKED;
      if (el.indeterminate) bits |= P.S_INDETERMINATE;
      if (el.defaultChecked) bits |= P.S_DEFAULT;
    } else if (isSubmitInput(el) && isDefaultButton(el)) {
      bits |= P.S_DEFAULT;
    }
  } else if (el instanceof HTMLButtonElement) {
    if (el.type === "submit" && isDefaultButton(el)) bits |= P.S_DEFAULT;
  } else if (el instanceof HTMLOptionElement) {
    // A select picks an option even without the selected attribute, and :checked follows it.
    if (el.selected) bits |= P.S_CHECKED;
    if (el.defaultSelected) bits |= P.S_DEFAULT;
  }
  return bits;
}

function disabledBits(el: Element): number {
  if (!supportsDisabled(el)) return 0;
  // A disabled fieldset disables the controls inside it, and a disabled option group or select
  // disables the options in it.
  let off = controlDisabled(el as HTMLElement);
  if (!off && el.localName === "option") {
    let a = el.parentElement;
    while (a !== null && !off) {
      if (a.localName === "optgroup" || a.localName === "select") off = attributeFlag(a, "disabled");
      a = a.parentElement;
    }
  }
  return off ? P.S_DISABLED : P.S_ENABLED;
}

function requiredBits(el: Element): number {
  if (!(el instanceof HTMLInputElement || el instanceof HTMLSelectElement
    || el instanceof HTMLTextAreaElement || el instanceof HTMLButtonElement)) return 0;
  return attributeFlag(el, "required") && supportsRequired(el) ? P.S_REQUIRED : P.S_OPTIONAL;
}

function editBits(el: Element): number {
  let writable = false;
  if (el instanceof HTMLInputElement) writable = textEntryType(el.type.toLowerCase()) && !el.readOnly;
  else if (el instanceof HTMLTextAreaElement) writable = !el.readOnly;
  else if (isContentEditableElement(el)) writable = true;
  // Everything else, a disabled or read-only field included, is :read-only.
  if (writable && controlDisabled(el as HTMLElement)) writable = false;
  return writable ? P.S_READ_WRITE : P.S_READ_ONLY;
}

function placeholderBits(el: Element): number {
  let shown = false;
  if (el instanceof HTMLInputElement) {
    shown = textEntryType(el.type.toLowerCase()) && el.placeholder !== "" && el.value === "";
  } else if (el instanceof HTMLTextAreaElement) {
    const p = el.getAttribute("placeholder");
    shown = p !== null && p !== "" && el.value === "";
  }
  return shown ? P.S_PLACEHOLDER_SHOWN : 0;
}

/** The range the field's value falls in; only number and range fields have one here. */
function rangeBits(el: Element): number {
  if (!(el instanceof HTMLInputElement) || !validationCandidate(el)) return 0;
  const type = el.type.toLowerCase();
  // A date family field is in range when it has a value and that value sits inside min and max.
  const dateType = dateKindOf(type);
  if (dateType !== null) {
    if (el.value === "") return 0;
    const pos = valuePosition(dateType, el.value);
    if (isNaN(pos)) return 0;
    const min = valuePosition(dateType, el.min);
    const max = valuePosition(dateType, el.max);
    return pos < min || pos > max ? P.S_OUT_OF_RANGE : P.S_IN_RANGE;
  }
  if (type !== "number" && type !== "range") return 0;
  const raw = el.value;
  let v = 0;
  if (raw !== "") {
    v = Number(raw);
    if (isNaN(v)) return 0;
  } else if (type === "range") {
    v = 50; // a range field's value when it has none is the midpoint of its range
  }
  const min = numberAttribute(el, "min", -Infinity);
  const max = numberAttribute(el, "max", Infinity);
  return v < min || v > max ? P.S_OUT_OF_RANGE : P.S_IN_RANGE;
}

function validBits(el: Element): number {
  if (!validationCandidate(el)) return 0;
  if (el instanceof HTMLButtonElement) return P.S_VALID;
  // An out-of-range value fails the field's constraints even though validity only reports the
  // constraints the form code checks, so the range state decides here too.
  if ((rangeBits(el) & P.S_OUT_OF_RANGE) !== 0) return P.S_INVALID;
  const field = el as HTMLInputElement;
  return field.validity.valid ? P.S_VALID : P.S_INVALID;
}

function focusWithinBits(el: Element): number {
  return focusState.el !== null && el.contains(focusState.el) ? P.S_FOCUS_WITHIN : 0;
}

/** A box's top edge relative to a scroll container's padding box, in unscrolled content px. */
function contentTop(el: Element, box: Element): number {
  let top = 0;
  let e: Node | null = el;
  while (e !== null && e !== box) {
    top += e.y;
    const p: Node | null = e.parentElement;
    if (p !== null && p !== box) top -= p.scrollY;
    e = p;
  }
  return top - box.borderWidth;
}

/**
 * Whether `el` is the child of its scroll container whose top the scrollport starts at — the
 * target a marker group's :target-current names. Before the first layout every box sits at zero,
 * so the first child is the target then.
 */
function targetCurrentBits(el: Element): number {
  const scroller = el.parentElement;
  if (scroller === null || scroller.scrollMarkers.length === 0) return 0;
  let current: Element | null = null;
  let laidOut = false;
  let first: Element | null = null;
  for (const box of scroller.scrollMarkers) {
    const origin = box.pseudoOrigin;
    if (origin === null || origin.parentElement !== scroller) continue;
    if (first === null) first = origin;
    if (origin.w === 0 && origin.h === 0) continue;
    laidOut = true;
    if (contentTop(origin, scroller) <= scroller.scrollY + 0.5) current = origin;
  }
  if (!laidOut) current = first;
  return current === el ? P.S_TARGET_CURRENT : 0;
}

/**
 * Works out the form state bits `need` asks about and stores them on the element, so a rule or
 * a DOM query tests them like any other pseudo-class. Only the groups asked for are recomputed.
 */
export function refreshFormState(el: Element, need: number): void {
  const mask = need & P.S_FORM_STATES;
  if (mask === 0) return;
  let state = el.state;
  if ((mask & FORM_CHECKED) !== 0) state = (state & ~FORM_CHECKED) | checkedBits(el);
  if ((mask & FORM_ENABLED) !== 0) state = (state & ~FORM_ENABLED) | disabledBits(el);
  if ((mask & FORM_REQUIRED) !== 0) state = (state & ~FORM_REQUIRED) | requiredBits(el);
  if ((mask & FORM_EDIT) !== 0) state = (state & ~FORM_EDIT) | editBits(el);
  if ((mask & P.S_PLACEHOLDER_SHOWN) !== 0) {
    state = (state & ~P.S_PLACEHOLDER_SHOWN) | placeholderBits(el);
  }
  if ((mask & FORM_VALID) !== 0) state = (state & ~FORM_VALID) | validBits(el);
  if ((mask & FORM_RANGE) !== 0) state = (state & ~FORM_RANGE) | rangeBits(el);
  if ((mask & P.S_FOCUS_WITHIN) !== 0) state = (state & ~P.S_FOCUS_WITHIN) | focusWithinBits(el);
  if ((mask & P.S_TARGET_CURRENT) !== 0) {
    state = (state & ~P.S_TARGET_CURRENT) | targetCurrentBits(el);
  }
  el.state = state;
}

/**
 * A control's checkedness, value or validity changed. A restyle follows when a rule anywhere
 * asks about a form state, since one control's change shows up in its own rules, its siblings'
 * and its form's alike; otherwise only the text the field draws changes.
 */
function noteControlChange(el: Element): void {
  // Rules on form states can restyle the field (and, through a sibling selector, its neighbours):
  // the subtree restyle asks the page whether that is safe and falls back to a page pass when not.
  if ((stateUsage.mask & P.S_FORM_STATES) !== 0) invalidateStyleOf(el);
  else markPaintDirty(el);
  // The accessibility tree carries the control's value and checked state either way.
  if (axChangeHook !== null) axChangeHook();
}

export class HTMLHeadElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLHeadElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("head", id, text, rules, states, inline);
  }
}

export class HTMLHeadingElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLHeadingElement"; }
  constructor(tag: string = "h1", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
}

export class HTMLHtmlElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLHtmlElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("html", id, text, rules, states, inline);
  }
}

export class HTMLIFrameElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLIFrameElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("iframe", id, text, rules, states, inline);
  }
  get src(): string {
    const v = this.getAttribute("src");
    return v === null ? "" : v;
  }
  set src(value: string) {
    this.setAttribute("src", value);
  }
  get srcdoc(): string {
    const v = this.getAttribute("srcdoc");
    return v === null ? "" : v;
  }
  set srcdoc(value: string) {
    this.setAttribute("srcdoc", value);
  }
  /** A frame isn't loaded here, so there is no content window or document in it. */
  get contentWindow(): null {
    return null;
  }
  get contentDocument(): null {
    return null;
  }
}


export class HTMLLabelElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLLabelElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("label", id, text, rules, states, inline);
  }
  /** The for attribute, which names the control the label is for. */
  get htmlFor(): string {
    const v = this.getAttribute("for");
    return v === null ? "" : v;
  }
  set htmlFor(value: string) {
    this.setAttribute("for", value);
  }
  get form(): HTMLFormElement | null {
    const c = this.control;
    return c === null ? null : formOwnerFor(c);
  }
  /** The control the label names: the one its for= gives, or the first labelable one inside it. */
  get control(): HTMLElement | null {
    const id = this.htmlFor;
    if (id !== "") {
      const found = document.getElementById(id);
      if (found !== null && isLabelable(found)) return found as HTMLElement;
      return null;
    }
    return labelableDescendant(this);
  }
}

export class HTMLLegendElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLLegendElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("legend", id, text, rules, states, inline);
  }
  get form(): HTMLFormElement | null {
    const p = this.parentNode;
    return p instanceof HTMLFieldSetElement ? formOwnerFor(p) : null;
  }
}

export class HTMLLIElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLLIElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("li", id, text, rules, states, inline);
  }
  /** The value attribute's number, or 0 when the item doesn't set one. */
  get value(): number {
    return numberAttribute(this, "value", 0);
  }
  set value(value: number) {
    this.setAttribute("value", String(value));
  }
}

/**
 * The engine behind a media element: decoding a source into an audio buffer, starting and
 * stopping it on a context, and the events a load, a play, a seek or an end sends. It lives in
 * runtime/media-element.ts and registers itself when the window loads, so this module doesn't
 * import the audio engine (which imports the event classes from here).
 */
export interface MediaDelegate {
  load(el: HTMLMediaElement): void;
  play(el: HTMLMediaElement): Promise<void>;
  pause(el: HTMLMediaElement): void;
  seek(el: HTMLMediaElement, time: number): void;
  volume(el: HTMLMediaElement): void;
  rate(el: HTMLMediaElement): void;
  loop(el: HTMLMediaElement): void;
}

let mediaDelegate: MediaDelegate | null = null;

/** Registers the engine side of a media element; called once as the window module loads. */
export function setMediaDelegate(delegate: MediaDelegate | null): void {
  mediaDelegate = delegate;
}

/** The hook that moves an element's sound into an AudioContext when a source node names it. */
let mediaRouteHook: ((el: HTMLMediaElement, context: any, node: any) => void) | null = null;

export function setMediaRouteHook(hook: ((el: HTMLMediaElement, context: any, node: any) => void) | null): void {
  mediaRouteHook = hook;
}

/** Routes an element's playback into `node`, a source node in `context`'s graph. */
export function routeMediaElement(el: HTMLMediaElement, context: any, node: any): void {
  if (mediaRouteHook !== null) mediaRouteHook(el, context, node);
}

export class HTMLMediaElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLMediaElement"; }
  static readonly NETWORK_EMPTY = 0;
  static readonly NETWORK_IDLE = 1;
  static readonly NETWORK_LOADING = 2;
  static readonly NETWORK_NO_SOURCE = 3;
  static readonly HAVE_NOTHING = 0;
  static readonly HAVE_METADATA = 1;
  static readonly HAVE_CURRENT_DATA = 2;
  static readonly HAVE_FUTURE_DATA = 3;
  static readonly HAVE_ENOUGH_DATA = 4;

  readonly NETWORK_EMPTY = 0;
  readonly NETWORK_IDLE = 1;
  readonly NETWORK_LOADING = 2;
  readonly NETWORK_NO_SOURCE = 3;
  readonly HAVE_NOTHING = 0;
  readonly HAVE_METADATA = 1;
  readonly HAVE_CURRENT_DATA = 2;
  readonly HAVE_FUTURE_DATA = 3;
  readonly HAVE_ENOUGH_DATA = 4;

  /** The engine's own state for this element (see runtime/media-element.ts). */
  _mediaState: any = null;
  /** The MediaElementAudioSourceNode made for this element, once one has. */
  _mediaSource: any = null;
  /** The context and node an element that hasn't loaded yet will play through. */
  _mediaContext: any = null;
  _mediaOutput: any = null;
  /** The URL the source resolved to, as currentSrc reports it. */
  currentSrc = "";
  paused = true;
  ended = false;
  duration = NaN;
  readyState = 0;
  networkState = 0;
  error: any = null;
  defaultPlaybackRate = 1;
  /** The volume and rate properties, which aren't attributes. */
  private volumeValue = 1;
  private rateValue = 1;
  /** The playhead, which a seek writes through the engine. */
  private timeValue = 0;

  constructor(tag: string = "audio", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }

  get src(): string {
    const value = this.getAttribute("src");
    return value === null ? "" : value;
  }
  set src(value: string) {
    this.setAttribute("src", value);
    this.load();
  }

  get currentTime(): number {
    return this.timeValue;
  }
  set currentTime(value: number) {
    if (!isFinite(value)) throw new TypeError("currentTime must be a finite number");
    const time = Math.max(0, value);
    this.timeValue = time;
    if (mediaDelegate !== null) mediaDelegate.seek(this, time);
  }

  /** The playhead as the engine ticks it, without going through a seek. */
  _setCurrentTime(value: number): void {
    this.timeValue = value;
  }

  get volume(): number {
    return this.volumeValue;
  }
  set volume(value: number) {
    const v = Number(value);
    if (!isFinite(v)) throw new TypeError("volume must be a finite number");
    this.volumeValue = Math.min(1, Math.max(0, v));
    this.dispatchEvent(new Event("volumechange"));
    if (mediaDelegate !== null) mediaDelegate.volume(this);
  }

  get playbackRate(): number {
    return this.rateValue;
  }
  set playbackRate(value: number) {
    const v = Number(value);
    if (!isFinite(v) || v <= 0) throw new TypeError("playbackRate must be a positive number");
    this.rateValue = v;
    if (mediaDelegate !== null) mediaDelegate.rate(this);
  }

  private boolAttr(name: string): boolean {
    return this.getAttribute(name) !== null;
  }
  private setBoolAttr(name: string, value: boolean): void {
    if (value) this.setAttribute(name, "");
    else this.removeAttribute(name);
  }

  get muted(): boolean { return this.boolAttr("muted"); }
  set muted(value: boolean) {
    this.setBoolAttr("muted", value);
    this.dispatchEvent(new Event("volumechange"));
    if (mediaDelegate !== null) mediaDelegate.volume(this);
  }

  get loop(): boolean { return this.boolAttr("loop"); }
  set loop(value: boolean) {
    this.setBoolAttr("loop", value);
    if (mediaDelegate !== null) mediaDelegate.loop(this);
  }

  get autoplay(): boolean { return this.boolAttr("autoplay"); }
  set autoplay(value: boolean) { this.setBoolAttr("autoplay", value); }

  get controls(): boolean { return this.boolAttr("controls"); }
  set controls(value: boolean) { this.setBoolAttr("controls", value); }

  get preload(): string {
    const value = this.getAttribute("preload");
    return value === null ? "auto" : value;
  }
  set preload(value: string) { this.setAttribute("preload", value); }

  /** No camera or stream source yet. */
  get srcObject(): any { return null; }
  set srcObject(value: any) {
    if (value !== null && value !== undefined) throw new Error("NotSupportedError: a media element can't take a stream yet");
  }

  /** The source type a caller asks about, as a browser answers: "probably", "maybe" or "". */
  canPlayType(type: string): string {
    const t = String(type).trim().toLowerCase();
    if (t === "") return "";
    // A video type is answered by the host's backend, since the formats each platform can play
    // differ: the platform decides, not this runtime.
    if (t.startsWith("video/")) {
      const answer = hostVideoCanPlay(t);
      return answer === 2 ? "probably" : answer === 1 ? "maybe" : "";
    }
    if (/^audio\/(mpeg|mp3|wav|wave|x-wav|ogg|vorbis|mp4|m4a|x-m4a|aac|flac)/.test(t)) return "probably";
    return "maybe";
  }

  /** Loads the element's src again, discarding any playhead. */
  load(): void {
    if (mediaDelegate === null) {
      this.readyState = 0;
      this.networkState = 0;
      this._setCurrentTime(0);
      this.duration = NaN;
      this.paused = true;
      this.ended = false;
      this.dispatchEvent(new Event("emptied"));
      return;
    }
    mediaDelegate.load(this);
  }

  /** Starts playing, resolving once it has started (or rejecting with the load's failure). */
  play(): Promise<void> {
    if (mediaDelegate === null) {
      return Promise.reject(new Error("NotSupportedError: this build has no audio engine"));
    }
    return mediaDelegate.play(this);
  }

  pause(): void {
    if (mediaDelegate !== null) mediaDelegate.pause(this);
  }

  /** A markup element takes the src attribute the build set, and starts loading. */
  adoptSource(): void {
    if (this.currentSrc !== "") return;
    const src = this.getAttribute("src");
    if (src === null || src === "") return;
    this.load();
  }

  setAttribute(name: string, value: any): void {
    super.setAttribute(name, value);
    if (name === "src") this.load();
    else if (name === "loop" && mediaDelegate !== null) mediaDelegate.loop(this);
    else if (name === "muted" && mediaDelegate !== null) mediaDelegate.volume(this);
  }

  removeAttribute(name: string): void {
    super.removeAttribute(name);
    if (name === "loop" && mediaDelegate !== null) mediaDelegate.loop(this);
    else if (name === "muted" && mediaDelegate !== null) mediaDelegate.volume(this);
  }
}

export class HTMLAudioElement extends HTMLMediaElement {
  get [Symbol.toStringTag](): string { return "HTMLAudioElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super("audio", id, text, rules, states, inline);
  }
}

export class HTMLVideoElement extends HTMLMediaElement {
  get [Symbol.toStringTag](): string { return "HTMLVideoElement"; }
  /** The picture's own size in pixels, 0 before the clip's metadata has loaded. */
  videoWidth = 0;
  videoHeight = 0;
  /** The host player's handle, or -1 before a load and after one that failed. */
  _videoId: number = -1;

  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("video", id, text, rules, states, inline);
  }

  /** The image shown before the first frame; not drawn yet. */
  get poster(): string {
    const value = this.getAttribute("poster");
    return value === null ? "" : value;
  }
  set poster(value: string) { this.setAttribute("poster", value); }
}

export class HTMLMenuElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLMenuElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("menu", id, text, rules, states, inline);
  }
}

export class HTMLMetaElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLMetaElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("meta", id, text, rules, states, inline);
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get content(): string {
    const v = this.getAttribute("content");
    return v === null ? "" : v;
  }
  set content(value: string) {
    this.setAttribute("content", value);
  }
}

export class HTMLMeterElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLMeterElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("meter", id, text, rules, states, inline);
  }
  /** The numbers the meter's value, ranges and optimum resolve to, clamped as the spec says. */
  private range(): { min: number; max: number; value: number; low: number; high: number; optimum: number } {
    const min = numberAttribute(this, "min", 0);
    let max = numberAttribute(this, "max", 1);
    if (max < min) max = min;
    let value = numberAttribute(this, "value", 0);
    if (value < min) value = min;
    else if (value > max) value = max;
    let low = numberAttribute(this, "low", min);
    if (low < min) low = min;
    else if (low > max) low = max;
    let high = numberAttribute(this, "high", max);
    if (high < low) high = low;
    else if (high > max) high = max;
    let optimum = numberAttribute(this, "optimum", (min + max) / 2);
    if (optimum < min) optimum = min;
    else if (optimum > max) optimum = max;
    return { min, max, value, low, high, optimum };
  }
  private setNumber(name: string, value: any): void {
    const n = Number(value);
    if (isNaN(n)) throw new TypeError(`Failed to set the '${name}' property on 'HTMLMeterElement': The provided double value is non-finite.`);
    this.setAttribute(name, String(n));
  }
  get value(): number { return this.range().value; }
  set value(value: any) { this.setNumber("value", value); }
  get min(): number { return this.range().min; }
  set min(value: any) { this.setNumber("min", value); }
  get max(): number { return this.range().max; }
  set max(value: any) { this.setNumber("max", value); }
  get low(): number { return this.range().low; }
  set low(value: any) { this.setNumber("low", value); }
  get high(): number { return this.range().high; }
  set high(value: any) { this.setNumber("high", value); }
  get optimum(): number { return this.range().optimum; }
  set optimum(value: any) { this.setNumber("optimum", value); }
}

export class HTMLOListElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLOListElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("ol", id, text, rules, states, inline);
  }
  get start(): number {
    return numberAttribute(this, "start", 1);
  }
  set start(value: number) {
    this.setAttribute("start", String(value));
  }
  get reversed(): boolean {
    return attributeFlag(this, "reversed");
  }
  set reversed(value: boolean) {
    setAttributeFlag(this, "reversed", value);
  }
  get type(): string {
    const v = this.getAttribute("type");
    return v === null ? "" : v;
  }
  set type(value: string) {
    this.setAttribute("type", value);
  }
}

export class HTMLOptGroupElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLOptGroupElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("optgroup", id, text, rules, states, inline);
  }
  get label(): string {
    const v = this.getAttribute("label");
    return v === null ? "" : v;
  }
  set label(value: string) {
    this.setAttribute("label", value);
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
}

export class HTMLOptionElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLOptionElement"; }
  /** Whether a script or the select picked this option, overriding the default selection. */
  selectedFlag = false;
  /** Whether that happened at all: until it does, the selected attribute and the select decide. */
  selectedSet = false;

  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("option", id, text, rules, states, inline);
  }
  get value(): string {
    const v = this.getAttribute("value");
    return v === null ? this.text : v;
  }
  set value(value: string) {
    this.setAttribute("value", value);
  }
  get text(): string {
    return this.textContent.replace(/\s+/g, " ").replace(/^ /, "").replace(/ $/, "");
  }
  set text(value: string) {
    this.textContent = value;
  }
  get label(): string {
    const v = this.getAttribute("label");
    return v === null ? this.text : v;
  }
  set label(value: string) {
    this.setAttribute("label", value);
  }
  /** Whether the option is selected. The select it belongs to keeps a single select to one. */
  get selected(): boolean {
    if (this.selectedSet) return this.selectedFlag;
    const s = this.selectElement();
    if (s === null) return this.defaultSelected;
    return s.isSelected(this);
  }
  set selected(value: boolean) {
    this.selectedFlag = value;
    this.selectedSet = true;
    // :checked follows selection, and the select's required-ness may turn valid or invalid.
    noteControlChange(this);
  }
  /** The selected attribute, which is the selection a form reset goes back to. */
  get defaultSelected(): boolean {
    return attributeFlag(this, "selected");
  }
  set defaultSelected(value: boolean) {
    setAttributeFlag(this, "selected", value);
  }
  get index(): number {
    const s = this.selectElement();
    if (s === null) return 0;
    return s.options.indexOf(this);
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
  get form(): HTMLFormElement | null {
    const s = this.selectElement();
    return s === null ? null : formOwnerFor(s);
  }
  /** The select this option is in, or null when it isn't in a select's list. */
  selectElement(): HTMLSelectElement | null {
    let p = this.parentNode;
    while (p !== null) {
      if (p instanceof HTMLSelectElement) return p;
      if (!(p instanceof HTMLElement)) return null;
      p = p.parentNode;
    }
    return null;
  }
}

/** The Option() constructor: an <option> whose text, value and selection the arguments set. */
export class Option extends HTMLOptionElement {
  constructor(text?: any, value?: any, defaultSelected?: any, selected?: any) {
    super("", "", [], 0, false);
    if (text !== undefined) this.text = String(text);
    if (value !== undefined) this.value = String(value);
    if (defaultSelected) this.defaultSelected = true;
    if (selected) this.selected = true;
  }
}

export class HTMLOutputElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLOutputElement"; }
  /** The message setCustomValidity() was given, which a failed check reports. */
  private customMessage = "";
  /** Whether a script set the value, which then stops following the element's text. */
  private valueMode = false;
  private storedValue = "";
  private storedDefault = "";
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("output", id, text, rules, states, inline);
  }
  get type(): string {
    return "output";
  }
  get value(): string {
    return this.valueMode ? this.storedValue : this.textContent;
  }
  set value(v: any) {
    const text = String(v);
    // Entering value mode keeps the default value the element showed until now.
    if (!this.valueMode) this.storedDefault = this.textContent;
    this.valueMode = true;
    this.storedValue = text;
    this.textContent = text;
  }
  get defaultValue(): string {
    return this.valueMode ? this.storedDefault : this.textContent;
  }
  set defaultValue(v: any) {
    const text = String(v);
    if (this.valueMode) this.storedDefault = text;
    else this.textContent = text;
  }
  /** An output is barred from constraint validation, so :valid and :invalid don't match it. */
  get willValidate(): boolean {
    return false;
  }
  get validity(): ValidityState {
    const state = new ValidityState();
    state.customError = this.customMessage !== "";
    return state;
  }
  get validationMessage(): string {
    return "";
  }
  checkValidity(): boolean {
    return true;
  }
  reportValidity(): boolean {
    return true;
  }
  setCustomValidity(message: string): void {
    this.customMessage = message;
    noteControlChange(this);
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
}

export class HTMLParagraphElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLParagraphElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("p", id, text, rules, states, inline);
  }
}

export class HTMLPreElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLPreElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("pre", id, text, rules, states, inline);
  }
}

export class HTMLProgressElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLProgressElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("progress", id, text, rules, states, inline);
  }
  /** The progress the element shows, clamped between zero and max; zero without a value. */
  get value(): number {
    if (!this.hasAttribute("value")) return 0;
    const max = this.max;
    const v = numberAttribute(this, "value", 0);
    return v < 0 ? 0 : v > max ? max : v;
  }
  set value(value: any) {
    this.setAttribute("value", String(Number(value)));
  }
  /** The value at which the bar is full: a missing, non-numeric or non-positive max is 1. */
  get max(): number {
    const m = numberAttribute(this, "max", 1);
    return m > 0 ? m : 1;
  }
  set max(value: any) {
    const n = Number(value);
    // A max that isn't a positive number leaves the one in place, as the spec says.
    if (!(n > 0)) return;
    this.setAttribute("max", String(n));
  }
  /** How far along the value is, from 0 to 1; -1 when the element has no value (indeterminate). */
  get position(): number {
    if (!this.hasAttribute("value")) return -1;
    return this.value / this.max;
  }
}

export class HTMLScriptElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLScriptElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("script", id, text, rules, states, inline);
  }
  get src(): string {
    const v = this.getAttribute("src");
    return v === null ? "" : v;
  }
  set src(value: string) {
    this.setAttribute("src", value);
  }
  get type(): string {
    const v = this.getAttribute("type");
    return v === null ? "" : v;
  }
  set type(value: string) {
    this.setAttribute("type", value);
  }
  get text(): string {
    return this.textContent;
  }
  set text(value: string) {
    this.textContent = value;
  }
}

export class HTMLSelectElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLSelectElement"; }
  /** The message setCustomValidity() was given, which a failed check reports. */
  private customMessage = "";

  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("select", id, text, rules, states, inline);
  }
  /** The options in the select, including those inside option groups, in document order. */
  get options(): HTMLOptionElement[] {
    const out: HTMLOptionElement[] = [];
    const all: Element[] = [];
    collectElements(this, all);
    for (const e of all) if (e instanceof HTMLOptionElement) out.push(e);
    return out;
  }
  get length(): number {
    return this.options.length;
  }
  /** Whether the field is a list box — `multiple`, or a `size` over one row — rather than a menu. */
  get isListBox(): boolean {
    return this.multiple || this.size > 1;
  }
  /** The rows a list box shows: its size, four for a multiple box, one otherwise. */
  get listRows(): number {
    const s = this.size;
    return s > 0 ? s : this.multiple ? 4 : 1;
  }
  /**
   * A press or a key choosing the option at `index`: `plain` takes it alone, `toggle` (Meta) adds
   * or removes it in a multiple box, and `extend` (Shift) takes the run from `anchor` to it. The
   * field sends input then change when the choice moved, as a browser's list box does.
   */
  selectRow(index: number, mode: string, anchor: number): void {
    const options = this.options;
    if (index < 0 || index >= options.length) return;
    const before: boolean[] = [];
    for (const o of options) before.push(this.isSelected(o));
    if (mode === "toggle" && this.multiple) {
      options[index].selected = !before[index];
    } else if (mode === "extend") {
      const from = Math.min(Math.max(anchor, 0), options.length - 1);
      const lo = Math.min(from, index);
      const hi = Math.max(from, index);
      for (let i = 0; i < options.length; i++) options[i].selected = i >= lo && i <= hi;
    } else {
      for (let i = 0; i < options.length; i++) options[i].selected = i === index;
    }
    let moved = false;
    for (let i = 0; i < options.length; i++) if (this.isSelected(options[i]) !== before[i]) moved = true;
    if (!moved) return;
    dispatch(trusted(new Event("input", { bubbles: true, composed: true })), this);
    dispatch(trusted(new Event("change", { bubbles: true })), this);
  }
  /** The label the field shows: its chosen option's, or "" when it has none chosen. */
  get chosenLabel(): string {
    for (const o of this.options) if (this.isSelected(o)) return o.label === "" ? o.text : o.label;
    return "";
  }
  get selectedOptions(): HTMLOptionElement[] {
    const out: HTMLOptionElement[] = [];
    for (const o of this.options) if (this.isSelected(o)) out.push(o);
    return out;
  }
  get selectedIndex(): number {
    const options = this.options;
    for (let i = 0; i < options.length; i++) if (this.isSelected(options[i])) return i;
    return -1;
  }
  set selectedIndex(index: number) {
    const options = this.options;
    for (let i = 0; i < options.length; i++) options[i].selected = i === index;
  }
  /** The first selected option's value, or "" when none is selected. */
  get value(): string {
    const options = this.options;
    for (const o of options) if (this.isSelected(o)) return o.value;
    return "";
  }
  set value(value: any) {
    const text = String(value);
    const options = this.options;
    let matched = false;
    for (const o of options) {
      const hit = !matched && o.value === text;
      o.selected = hit;
      if (hit) matched = true;
    }
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
  get multiple(): boolean {
    return attributeFlag(this, "multiple");
  }
  set multiple(value: boolean) {
    setAttributeFlag(this, "multiple", value);
  }
  get required(): boolean {
    return attributeFlag(this, "required");
  }
  set required(value: boolean) {
    setAttributeFlag(this, "required", value);
  }
  get size(): number {
    return numberAttribute(this, "size", 0);
  }
  set size(value: number) {
    this.setAttribute("size", String(value));
  }
  get labels(): HTMLLabelElement[] {
    return labelsFor(this);
  }
  /** The option at `index`, or null past the end. */
  item(index: number): HTMLOptionElement | null {
    const options = this.options;
    return index >= 0 && index < options.length ? options[index] : null;
  }
  /** The option whose id or name attribute is `name`. */
  namedItem(name: string): HTMLOptionElement | null {
    for (const o of this.options) {
      if (o.getAttribute("id") === name || o.getAttribute("name") === name) return o;
    }
    return null;
  }
  add(element: HTMLOptionElement, before?: number | HTMLOptionElement | null): void {
    if (before === undefined || before === null) {
      this.appendChild(element);
    } else if (typeof before === "number") {
      const ref = this.item(before);
      this.insertBefore(element, ref);
    } else {
      this.insertBefore(element, before);
    }
    if (!this.multiple && this.value === "" && element.selected) this.value = element.value;
  }
  remove(index?: number): void {
    if (index === undefined) {
      super.remove();
      return;
    }
    const option = this.item(index);
    if (option !== null) this.removeChild(option);
  }
  /** Whether `option` is shown as selected, with the default a browser picks when nothing says. */
  isSelected(option: HTMLOptionElement): boolean {
    const options = this.options;
    const index = options.indexOf(option);
    if (index < 0) return option.selectedFlag;
    // Once something has picked options, those choices decide; before that, the selected
    // attributes do, and a single select with no selected option shows its first one.
    let picked = false;
    for (const o of options) if (o.selectedSet) { picked = true; break; }
    if (picked) {
      if (this.multiple) return option.selectedFlag;
      let last = -1;
      for (let i = 0; i < options.length; i++) {
        if (options[i].selectedSet && options[i].selectedFlag) last = i;
      }
      return index === last;
    }
    if (this.multiple) return option.defaultSelected;
    for (let i = 0; i < options.length; i++) if (options[i].defaultSelected) return index === i;
    for (let i = 0; i < options.length; i++) if (!options[i].disabled) return index === i;
    return false;
  }
  /** Whether the select takes part in validation: a disabled one, or one a disabled fieldset
   *  holds, is barred from it. */
  get willValidate(): boolean {
    return !controlDisabled(this);
  }
  /** The constraints the select fails: a required select with no option selected. */
  get validity(): ValidityState {
    const state = new ValidityState();
    state.customError = this.customMessage !== "";
    state.valueMissing = this.willValidate && this.required && this.selectedIndex < 0;
    return state;
  }
  get validationMessage(): string {
    const state = this.validity;
    if (state.customError) return this.customMessage;
    if (state.valueMissing) return "Please select an item in the list.";
    return "";
  }
  checkValidity(): boolean {
    const state = this.validity;
    if (state.valid) return true;
    dispatch(trusted(new Event("invalid", { cancelable: true })), this);
    return false;
  }
  reportValidity(): boolean {
    return this.checkValidity();
  }
  setCustomValidity(message: string): void {
    this.customMessage = message;
    noteControlChange(this);
  }
}

export class HTMLSlotElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLSlotElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("slot", id, text, rules, states, inline);
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  /** The nodes a manual-assignment shadow root gave this slot with assign(), or null. */
  manualAssigned: Node[] | null = null;

  /**
   * Gives the slot its nodes in a shadow tree whose `slotAssignment` is "manual": the nodes are
   * exactly these, whatever their `slot` attribute says. A node is in one slot at a time, so it
   * leaves the slot that had it; every slot whose list changed fires `slotchange`.
   */
  assign(...args: (Element | Text)[]): void {
    const root = shadowRootOfNode(this);
    if (root === null || root.slotAssignment !== "manual") {
      throw new Error("NotSupportedError: Failed to execute 'assign' on 'HTMLSlotElement': The slot must be in a shadow root whose slot assignment is 'manual'.");
    }
    // Narrow each argument to a Node here: scriptc can't convert a (Element | Text)[] into the
    // Node[] | null the slot keeps.
    const nodes: Node[] = [];
    for (const a of args) {
      if (a instanceof Element) nodes.push(a);
      else if (a instanceof Text) nodes.push(a);
      else {
        throw new TypeError("TypeError: Failed to execute 'assign' on 'HTMLSlotElement': The provided value is not of type '(Element or Text)'.");
      }
    }
    const affected: Element[] = [];
    const before = this.manualAssigned;
    if (before !== null) {
      for (const n of before) {
        let kept = false;
        for (const k of nodes) if (k === n) kept = true;
        if (kept || n.manualSlot !== this) continue;
        n.manualSlot = null;
        if (affected.indexOf(this) < 0) affected.push(this);
      }
    }
    for (const n of nodes) {
      const prev = n.manualSlot;
      if (prev !== null && prev !== this && prev instanceof HTMLSlotElement && prev.manualAssigned !== null) {
        let at = -1;
        for (let i = 0; i < prev.manualAssigned.length; i++) if (prev.manualAssigned[i] === n) at = i;
        if (at >= 0) prev.manualAssigned.splice(at, 1);
        if (affected.indexOf(prev) < 0) affected.push(prev);
      }
      n.manualSlot = this;
    }
    this.manualAssigned = nodes;
    if (affected.indexOf(this) < 0) affected.push(this);
    for (const slot of affected) {
      const now = assignedOf(slot);
      const had = slot.assignedSnapshot;
      const changed = had === null ? now.length > 0 : !sameNodes(had, now);
      slot.assignedSnapshot = now.slice();
      if (changed) dispatch(trusted(new Event("slotchange")), slot);
    }
    invalidateStyle();
  }

  /**
   * The nodes the slot was given: the host's light children whose `slot` attribute names this
   * slot (the ones that name none go to the default slot). Empty when the host gave it none, and
   * layout then draws the slot's own children.
   */
  assignedNodes(options?: { flatten?: boolean }): Node[] {
    const assigned = assignedOf(this);
    if (options === undefined || options.flatten !== true) return assigned.slice();
    const out: Node[] = [];
    flattenAssigned(assigned, out);
    return out;
  }
  assignedElements(): Element[] {
    const out: Element[] = [];
    for (const n of this.assignedNodes()) if (n.isElementNode) out.push(n as Element);
    return out;
  }
}

export class HTMLSpanElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLSpanElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("span", id, text, rules, states, inline);
  }
}

/**
 * A sheet-owning element's `media` or `disabled` attribute changed, by a setter or by setAttribute
 * and removeAttribute alike. A <style>'s sheet follows its media list; a <link>'s rules are only
 * in the build's tables and it has no sheet object, so the sheet index the element carries tells
 * the style engine directly.
 */
function noteSheetAttr(el: Element, name: string, value: string | null): void {
  if (name === "media") {
    if (el.localName === "style" && el instanceof HTMLStyleElement && el.sheet !== null) {
      el.sheet.media.mediaText = value === null ? "" : value;
    } else if (el.localName === "link" && el instanceof HTMLLinkElement) {
      setCompiledSheetMediaByIndex(el.sheetIndex, value === null ? "" : value);
    }
  } else if (name === "disabled" && el.localName === "link" && el instanceof HTMLLinkElement) {
    setCompiledSheetOffByIndex(el.sheetIndex, value !== null);
  }
}

export class HTMLStyleElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLStyleElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("style", id, text, rules, states, inline);
  }
  /**
   * Whether the element's sheet takes part in the cascade — the CSSOM's
   * `HTMLStyleElement.disabled`. It is the sheet's own flag, not a content attribute, as in a
   * browser: a <style> the build compiled keeps its rules in the page's tables, and the flag
   * reaches them through the sheet's compiled index (sheets.ts, style.ts).
   */
  get disabled(): boolean {
    return this.sheet !== null && this.sheet.disabledFlag;
  }
  set disabled(value: boolean) {
    if (this.sheet === null) refreshSheet(this);
    if (this.sheet !== null) this.sheet.disabled = Boolean(value);
  }
  get media(): string {
    const v = this.getAttribute("media");
    return v === null ? "" : v;
  }
  set media(value: string) {
    this.setAttribute("media", value);
    // An element that was never connected has no sheet yet; one that has follows the attribute
    // through noteSheetAttr, which re-runs the cascade, so a `print` sheet starts applying the
    // moment a script says `media = "screen"`.
    if (this.sheet === null) refreshSheet(this);
  }
  get type(): string {
    const v = this.getAttribute("type");
    return v === null ? "" : v;
  }
  set type(value: string) {
    this.setAttribute("type", value);
  }
}

export class HTMLSummaryElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLSummaryElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("summary", id, text, rules, states, inline);
  }
}

export class HTMLTableCaptionElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableCaptionElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("caption", id, text, rules, states, inline);
  }
}

/** The nearest table ancestor of a node, which decides the table a row belongs to. */
function nearestTable(node: Node): Node | null {
  let p = node.parentNode;
  while (p !== null) {
    if (p.isElementNode && (p as Element).localName === "table" && (p as Element).namespaceURI === HTML_NS) return p;
    p = p.parentNode;
  }
  return null;
}

/** A new row, cell or section for the table-insertion methods, in the HTML namespace. */
function newTableChild(tag: string): HTMLElement {
  return newElementFor(tag, "", "", [], 0, false);
}

/** `el` as a section of the given kind, or null: a tbody in another namespace isn't one. */
function sectionOf(el: Element | null, tag: string): HTMLTableSectionElement | null {
  return el !== null && el instanceof HTMLTableSectionElement && el.localName === tag &&
    el.namespaceURI === HTML_NS ? el : null;
}

export class HTMLTableCellElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableCellElement"; }
  constructor(tag: string = "td", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
  get colSpan(): number {
    return numberAttribute(this, "colspan", 1);
  }
  set colSpan(value: number) {
    this.setAttribute("colspan", String(value));
  }
  get rowSpan(): number {
    return numberAttribute(this, "rowspan", 1);
  }
  set rowSpan(value: number) {
    this.setAttribute("rowspan", String(value));
  }
  /** The cell's position among its row's cells, or -1 when it isn't one of them. */
  get cellIndex(): number {
    const p = this.parentNode;
    if (!(p instanceof HTMLTableRowElement) || p.namespaceURI !== HTML_NS || p.localName !== "tr") return -1;
    if (this.namespaceURI !== HTML_NS || (this.localName !== "td" && this.localName !== "th")) return -1;
    return p.cells.indexOf(this);
  }
}

export class HTMLTableColElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableColElement"; }
  constructor(tag: string = "col", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
  get span(): number {
    return numberAttribute(this, "span", 1);
  }
  set span(value: number) {
    this.setAttribute("span", String(value));
  }
}

export class HTMLTableElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("table", id, text, rules, states, inline);
  }
  /** The table's first caption child, or null. */
  get caption(): HTMLTableCaptionElement | null {
    for (const c of this.children) {
      if (c instanceof HTMLTableCaptionElement && c.namespaceURI === HTML_NS) return c;
    }
    return null;
  }
  set caption(value: HTMLTableCaptionElement | null) {
    const old = this.caption;
    if (value === null) {
      if (old !== null) this.removeChild(old);
      return;
    }
    if (!(value instanceof HTMLTableCaptionElement) || value.namespaceURI !== HTML_NS) {
      throw new Error("TypeError: Failed to set the 'caption' property on 'HTMLTableElement': The provided value is not a caption element.");
    }
    if (old === value) return;
    if (old !== null) this.replaceChild(value, old);
    else this.insertBefore(value, this.firstChild);
  }
  /** The table's first thead child, or null. */
  private section(tag: string): HTMLTableSectionElement | null {
    for (const c of this.children) if (sectionOf(c, tag) !== null) return c as HTMLTableSectionElement;
    return null;
  }
  get tHead(): HTMLTableSectionElement | null {
    return this.section("thead");
  }
  set tHead(value: HTMLTableSectionElement | null) {
    const old = this.tHead;
    if (value === null) {
      if (old !== null) this.removeChild(old);
      return;
    }
    if (!(value instanceof HTMLTableSectionElement)) {
      throw new Error("TypeError: Failed to set the 'tHead' property on 'HTMLTableElement': The provided value is not a table section element.");
    }
    if (value.localName !== "thead" || value.namespaceURI !== HTML_NS) {
      throw new Error("HierarchyRequestError: Failed to set the 'tHead' property on 'HTMLTableElement': Only a thead may be the table's head.");
    }
    if (old === value) return;
    if (old !== null) this.replaceChild(value, old);
    else this.insertSection(value, true);
  }
  get tFoot(): HTMLTableSectionElement | null {
    return this.section("tfoot");
  }
  set tFoot(value: HTMLTableSectionElement | null) {
    const old = this.tFoot;
    if (value === null) {
      if (old !== null) this.removeChild(old);
      return;
    }
    if (!(value instanceof HTMLTableSectionElement)) {
      throw new Error("TypeError: Failed to set the 'tFoot' property on 'HTMLTableElement': The provided value is not a table section element.");
    }
    if (value.localName !== "tfoot" || value.namespaceURI !== HTML_NS) {
      throw new Error("HierarchyRequestError: Failed to set the 'tFoot' property on 'HTMLTableElement': Only a tfoot may be the table's foot.");
    }
    if (old === value) return;
    if (old !== null) this.replaceChild(value, old);
    else this.insertSection(value, false);
  }
  /** The table's tbody children, live. */
  get tBodies(): HTMLCollection {
    return new HTMLCollection(this, COLL_TABLE_SECTIONS, "");
  }
  /** The table's rows, in tree order and including its sections' rows, live. */
  get rows(): HTMLCollection {
    return new HTMLCollection(this, COLL_TABLE_ROWS, "");
  }
  /** Puts a head or foot where the sheet's order wants it: a head before the first body, a foot
   *  after the last one. */
  private insertSection(value: HTMLTableSectionElement, head: boolean): void {
    const at = this.children;
    if (head) {
      let ref: Element | null = null;
      for (const c of at) {
        const isCaption = c instanceof HTMLTableCaptionElement && c.namespaceURI === HTML_NS;
        const isColgroup = c.localName === "colgroup" && c.namespaceURI === HTML_NS;
        if (!isCaption && !isColgroup) { ref = c; break; }
      }
      this.insertBefore(value, ref);
    } else {
      this.appendChild(value);
    }
  }
  /** The table's caption, created as the first child when it has none. */
  createCaption(): HTMLTableCaptionElement {
    const old = this.caption;
    if (old !== null) return old;
    const caption = newTableChild("caption") as HTMLTableCaptionElement;
    this.insertBefore(caption, this.firstChild);
    return caption;
  }
  deleteCaption(): void {
    const old = this.caption;
    if (old !== null) this.removeChild(old);
  }
  createTHead(): HTMLTableSectionElement {
    const old = this.tHead;
    if (old !== null) return old;
    const head = newTableChild("thead") as HTMLTableSectionElement;
    this.insertSection(head, true);
    return head;
  }
  deleteTHead(): void {
    const old = this.tHead;
    if (old !== null) this.removeChild(old);
  }
  createTFoot(): HTMLTableSectionElement {
    const old = this.tFoot;
    if (old !== null) return old;
    const foot = newTableChild("tfoot") as HTMLTableSectionElement;
    this.insertSection(foot, false);
    return foot;
  }
  deleteTFoot(): void {
    const old = this.tFoot;
    if (old !== null) this.removeChild(old);
  }
  /** A new body section, put after the last tbody child the table has. */
  createTBody(): HTMLTableSectionElement {
    const body = newTableChild("tbody") as HTMLTableSectionElement;
    let last: Element | null = null;
    for (const c of this.children) if (sectionOf(c, "tbody") !== null) last = c;
    if (last === null) this.appendChild(body);
    else this.insertBefore(body, last.nextSibling);
    return body;
  }
  /**
   * A new row at `index` among the table's rows: at the end when the index is -1 or the row
   * count, and in the section that holds the row it goes before otherwise. A table with no rows
   * gets a tbody to hold the first one.
   */
  insertRow(index: number = -1): HTMLTableRowElement {
    const rows = this.rows;
    if (index < -1 || index > rows.length) {
      throw new Error(`IndexSizeError: Failed to execute 'insertRow' on 'HTMLTableElement': The index provided (${index}) is greater than the number of rows in the table (${rows.length}).`);
    }
    const row = newTableChild("tr") as HTMLTableRowElement;
    if (rows.length === 0) {
      let body: HTMLTableSectionElement | null = null;
      for (const c of this.children) if (sectionOf(c, "tbody") !== null) body = c as HTMLTableSectionElement;
      if (body === null) {
        body = newTableChild("tbody") as HTMLTableSectionElement;
        this.appendChild(body);
      }
      body.appendChild(row);
      return row;
    }
    if (index === -1 || index === rows.length) {
      const last = rows[rows.length - 1];
      const parent = last.parentNode;
      if (parent !== null) parent.appendChild(row);
      else this.appendChild(row);
      return row;
    }
    const ref = rows[index];
    const parent = ref.parentNode;
    if (parent !== null) parent.insertBefore(row, ref);
    else this.insertBefore(row, ref);
    return row;
  }
  /** Removes the row at `index`, or the last one when it is -1. */
  deleteRow(index: number = -1): void {
    const rows = this.rows;
    if (index === -1 && rows.length === 0) return;
    if (index < -1 || index >= rows.length) {
      throw new Error(`IndexSizeError: Failed to execute 'deleteRow' on 'HTMLTableElement': The index provided (${index}) is greater than the number of rows in the table (${rows.length}).`);
    }
    const row = rows[index === -1 ? rows.length - 1 : index];
    const parent = row.parentNode;
    if (parent !== null) parent.removeChild(row);
  }
}

export class HTMLTableRowElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableRowElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("tr", id, text, rules, states, inline);
  }
  /** The row's cells, live: its td and th children only. */
  get cells(): HTMLCollection {
    return new HTMLCollection(this, COLL_ROW_CELLS, "");
  }
  /** The row's position among its table's rows, or -1 outside a table. */
  get rowIndex(): number {
    const table = nearestTable(this);
    if (table === null) return -1;
    return (table as HTMLTableElement).rows.indexOf(this);
  }
  /** The row's position among the rows of the section it is in, or among the rows that are its
   *  table's own children (the body the parser implies around them). */
  get sectionRowIndex(): number {
    const p = this.parentNode;
    if (p instanceof HTMLTableSectionElement) return p.rows.indexOf(this);
    if (p instanceof HTMLTableElement) {
      let index = 0;
      for (const c of p.children) {
        if (c === this) return index;
        if (c instanceof HTMLTableRowElement && c.parentNode === p) index++;
      }
      return -1;
    }
    return -1;
  }
  /** A new cell at `index`: before the cell there, or last when the index is -1 or the count. */
  insertCell(index: number = -1): HTMLTableCellElement {
    const cells = this.cells;
    if (index < -1 || index > cells.length) {
      throw new Error(`IndexSizeError: Failed to execute 'insertCell' on 'HTMLTableRowElement': The index provided (${index}) is outside the range of the row's cells (0 to ${cells.length}).`);
    }
    const cell = newTableChild("td") as HTMLTableCellElement;
    if (index === -1 || index === cells.length) this.appendChild(cell);
    else this.insertBefore(cell, cells[index]);
    return cell;
  }
  /** Removes the cell at `index`, or the last one when it is -1. */
  deleteCell(index: number = -1): void {
    const cells = this.cells;
    if (index < -1 || index >= cells.length) {
      throw new Error(`IndexSizeError: Failed to execute 'deleteCell' on 'HTMLTableRowElement': The index provided (${index}) is outside the range of the row's cells (0 to ${cells.length}).`);
    }
    if (cells.length === 0) return;
    this.removeChild(cells[index === -1 ? cells.length - 1 : index]);
  }
}

export class HTMLTableSectionElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTableSectionElement"; }
  constructor(tag: string = "tbody", id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl(tag, id, text, rules, states, inline);
  }
  /** The section's rows, live: its direct tr children only. */
  get rows(): HTMLCollection {
    return new HTMLCollection(this, COLL_SECTION_ROWS, "");
  }
  /** A new row at `index` among the section's rows. */
  insertRow(index: number = -1): HTMLTableRowElement {
    const rows = this.rows;
    if (index < -1 || index > rows.length) {
      throw new Error(`IndexSizeError: Failed to execute 'insertRow' on 'HTMLTableSectionElement': The index provided (${index}) is outside the range of the section's rows (0 to ${rows.length}).`);
    }
    const row = newTableChild("tr") as HTMLTableRowElement;
    if (index === -1 || index === rows.length) this.appendChild(row);
    else this.insertBefore(row, rows[index]);
    return row;
  }
  /** Removes the row at `index`, or the last one when it is -1. */
  deleteRow(index: number = -1): void {
    const rows = this.rows;
    if (index === -1 && rows.length === 0) return;
    if (index < -1 || index >= rows.length) {
      throw new Error(`IndexSizeError: Failed to execute 'deleteRow' on 'HTMLTableSectionElement': The index provided (${index}) is outside the range of the section's rows (0 to ${rows.length}).`);
    }
    this.removeChild(rows[index === -1 ? rows.length - 1 : index]);
  }
}

export class HTMLTextAreaElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTextAreaElement"; }
  /** Where the selection starts and ends, in the text. */
  selectionStart = 0;
  selectionEnd = 0;
  /** The end the selection grows from when it is extended. */
  anchor = 0;
  /** The message setCustomValidity() was given, which a failed check reports. */
  private customMessage = "";
  /** The text the element was authored with, which a form reset goes back to. */
  private defaultText: string | null = null;
  /** The value ranges a script made over this control's text. */
  readonly valueRanges: OpaqueRange[] = [];

  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("textarea", id, text, rules, states, inline);
  }
  /** A textarea shows its text, so its value and its text are the same here. */
  get value(): string {
    return this.textContent;
  }
  /**
   * The text the field lays out: its value, where it holds it. An element lays out its own text,
   * but a field's may have become a text child of it — reading the field's children (childNodes,
   * firstChild, a Range, a walker) turns its own text into the #text child a browser has there,
   * and inserting a child does the same. The field draws its text whichever way it holds it, as
   * a browser draws its value.
   */
  get flowText(): string {
    return this.value;
  }
  set value(value: any) {
    const text = String(value);
    const old = this.textContent;
    this.writeText(text, 0, old.length, text.length);
    this.selectionStart = text.length;
    this.selectionEnd = text.length;
    this.anchor = text.length;
    this.caretEnd = text.length;
    noteControlChange(this);
  }
  /**
   * Replaces the field's text, from `from` to `to`, and moves its value ranges past the edit as
   * the spec's replace data does. The text is the field's own, as the markup's is: a browser keeps
   * a textarea's value out of the tree, and its text child (if any) is the default value's.
   */
  private writeText(next: string, from: number, to: number, replacedLength: number): void {
    if (this.defaultText === null) this.defaultText = this.textContent;
    // Writing the same text changes nothing, so a live value range stays where it was.
    if (next !== this.textContent) moveValueRanges(this, from, to - from, replacedLength);
    this.kids = [];
    this.ownText = next;
    // The text decides the lines the field lays out and the box it wants, as a text child of
    // any other element would; a page whose rules can't see past the field restyles just it.
    noteStructureChange(this);
    invalidateStyleOf(this);
  }
  /** The text the element started with; a form reset puts it back. */
  get defaultValue(): string {
    return this.defaultText === null ? this.textContent : this.defaultText;
  }
  set defaultValue(value: string) {
    this.defaultText = value;
    this.value = value;
  }
  get type(): string {
    return "textarea";
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(value: string) {
    this.setAttribute("name", value);
  }
  get placeholder(): string {
    const v = this.getAttribute("placeholder");
    return v === null ? "" : v;
  }
  set placeholder(value: string) {
    this.setAttribute("placeholder", value);
  }
  get rows(): number {
    return numberAttribute(this, "rows", 2);
  }
  set rows(value: number) {
    this.setAttribute("rows", String(value));
  }
  get cols(): number {
    return numberAttribute(this, "cols", 20);
  }
  set cols(value: number) {
    this.setAttribute("cols", String(value));
  }
  get textLength(): number {
    return this.textContent.length;
  }
  get disabled(): boolean {
    return attributeFlag(this, "disabled");
  }
  set disabled(value: boolean) {
    setAttributeFlag(this, "disabled", value);
  }
  get readOnly(): boolean {
    return attributeFlag(this, "readonly");
  }
  set readOnly(value: boolean) {
    setAttributeFlag(this, "readonly", value);
  }
  get required(): boolean {
    return attributeFlag(this, "required");
  }
  set required(value: boolean) {
    setAttributeFlag(this, "required", value);
  }
  /** maxlength as the IDL property reads it: -1 when the attribute is unset or invalid. */
  get maxLength(): number {
    return maxLengthOf(this);
  }
  set maxLength(v: any) {
    setLengthAttribute(this, "maxlength", v);
  }
  /** minlength as the IDL property reads it: -1 when the attribute is unset or invalid. */
  get minLength(): number {
    return minLengthOf(this);
  }
  set minLength(v: any) {
    setLengthAttribute(this, "minlength", v);
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  get labels(): HTMLLabelElement[] {
    return labelsFor(this);
  }
  /** Which end the selection is anchored at, and so which way a shift-click extends it. */
  get selectionDirection(): string {
    if (this.selectionStart === this.selectionEnd) return "none";
    return this.anchor === this.selectionStart ? "forward" : "backward";
  }
  set selectionDirection(direction: string) {
    if (direction === "backward" && this.selectionStart !== this.selectionEnd) {
      const swap = this.selectionStart;
      this.selectionStart = this.selectionEnd;
      this.selectionEnd = swap;
      this.anchor = this.selectionEnd;
    } else if (direction === "none") {
      this.selectionStart = this.selectionEnd;
      this.anchor = this.selectionEnd;
    } else {
      this.anchor = this.selectionStart;
    }
  }
  select(): void {
    this.anchor = 0;
    this.selectionStart = 0;
    this.selectionEnd = this.textContent.length;
    this.caretEnd = this.selectionEnd;
    invalidatePaint();
  }
  setSelectionRange(start: number, end: number, direction: string = "none"): void {
    const n = this.textContent.length;
    this.selectionStart = Math.max(0, Math.min(start, n));
    this.selectionEnd = Math.max(this.selectionStart, Math.min(end, n));
    if (direction === "backward") {
      this.anchor = this.selectionEnd;
      const swap = this.selectionStart;
      this.selectionStart = this.selectionEnd;
      this.selectionEnd = swap;
    } else {
      this.anchor = this.selectionStart;
    }
    // The caret is drawn at the moving end, and an edit acts there, as in an input.
    this.caretEnd = this.selectionEnd;
    invalidatePaint();
  }
  /** Replaces the text from `start` to `end`, then moves the selection as `mode` says. */
  setRangeText(replacement: string, start?: number, end?: number, mode: string = "preserve"): void {
    const text = this.textContent;
    const from = start === undefined ? this.selectionStart : start;
    const to = end === undefined ? this.selectionEnd : end;
    const next = text.slice(0, from) + replacement + text.slice(to);
    this.writeText(next, from, to, replacement.length);
    if (mode === "select") {
      this.selectionStart = from;
      this.selectionEnd = from + replacement.length;
    } else if (mode === "start") {
      this.selectionStart = from;
      this.selectionEnd = from;
    } else if (mode === "end") {
      this.selectionStart = from + replacement.length;
      this.selectionEnd = from + replacement.length;
    }
    this.anchor = this.selectionStart;
    this.caretEnd = this.selectionEnd;
    invalidatePaint();
  }
  /** The moving end of the selection (where the caret is drawn). */
  caretEnd = 0;
  /** The marked text an input method is composing, as a range in the value, or -1 for none. */
  composeStart = -1;
  composeEnd = -1;
  /** The value at focus or the last change event, for deciding when "change" fires. */
  private committed = "";

  /** Moves the caret to `pos`; with `extend`, grows the selection from the anchor instead. */
  moveCaret(pos: number, extend: boolean): void {
    const n = this.value.length;
    pos = Math.max(0, Math.min(pos, n));
    if (!extend) this.anchor = pos;
    this.selectionStart = Math.min(this.anchor, pos);
    this.selectionEnd = Math.max(this.anchor, pos);
    this.caretEnd = pos;
    markPaintDirty(this);
  }

  /** Replaces the selection with `text`, leaving the caret after it. */
  replaceSelection(text: string): void {
    const v = this.value;
    const s = this.selectionStart;
    const e = this.selectionEnd;
    this.writeText(v.slice(0, s) + text + v.slice(e), s, e, text.length);
    this.moveCaret(s + text.length, false);
    noteControlChange(this);
    if (axChangeHook !== null) axChangeHook();
  }

  /** Fires "change" if the value differs from the last committed value. */
  commit(): void {
    const v = this.value;
    if (v !== this.committed) {
      this.committed = v;
      dispatch(trusted(new Event("change", { bubbles: true })), this);
    }
  }
  /** Whether the textarea takes part in validation: a disabled one (or one a disabled fieldset
   *  holds) and a read-only one are barred. */
  get willValidate(): boolean {
    return !controlDisabled(this) && !this.readOnly;
  }
  /** The constraints the textarea fails: a required one with no text, and its length bounds. */
  get validity(): ValidityState {
    const state = new ValidityState();
    state.customError = this.customMessage !== "";
    state.valueMissing = this.willValidate && this.required && this.value === "";
    return state;
  }
  get validationMessage(): string {
    const state = this.validity;
    if (state.customError) return this.customMessage;
    if (state.valueMissing) return "Please fill out this field.";
    return "";
  }
  checkValidity(): boolean {
    const state = this.validity;
    if (state.valid) return true;
    dispatch(trusted(new Event("invalid", { cancelable: true })), this);
    return false;
  }
  reportValidity(): boolean {
    return this.checkValidity();
  }
  setCustomValidity(message: string): void {
    this.customMessage = message;
    noteControlChange(this);
  }
}

export class HTMLTimeElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTimeElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = true) {
    super();
    this.initEl("time", id, text, rules, states, inline);
  }
  get dateTime(): string {
    const v = this.getAttribute("datetime");
    return v === null ? "" : v;
  }
  set dateTime(value: string) {
    this.setAttribute("datetime", value);
  }
}

export class HTMLTitleElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTitleElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("title", id, text, rules, states, inline);
  }
  get text(): string {
    return this.textContent;
  }
  set text(value: string) {
    this.textContent = value;
  }
}

export class HTMLUListElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLUListElement"; }
  constructor(id: string = "", text: string = "", rules: readonly number[] = [], states: number = 0, inline: boolean = false) {
    super();
    this.initEl("ul", id, text, rules, states, inline);
  }
}

/** The class each tag name makes, for the types querySelector and getElementById give back. */
export interface HTMLElementTagNameMap {
  a: HTMLAnchorElement;
  area: HTMLAreaElement;
  audio: HTMLMediaElement;
  base: HTMLBaseElement;
  body: HTMLBodyElement;
  br: HTMLBRElement;
  button: HTMLButtonElement;
  caption: HTMLTableCaptionElement;
  col: HTMLTableColElement;
  colgroup: HTMLTableColElement;
  datalist: HTMLDataListElement;
  details: HTMLDetailsElement;
  dialog: HTMLDialogElement;
  div: HTMLDivElement;
  fieldset: HTMLFieldSetElement;
  form: HTMLFormElement;
  h1: HTMLHeadingElement;
  h2: HTMLHeadingElement;
  h3: HTMLHeadingElement;
  h4: HTMLHeadingElement;
  h5: HTMLHeadingElement;
  h6: HTMLHeadingElement;
  head: HTMLHeadElement;
  html: HTMLHtmlElement;
  iframe: HTMLIFrameElement;
  img: HTMLImageElement;
  input: HTMLInputElement;
  label: HTMLLabelElement;
  legend: HTMLLegendElement;
  li: HTMLLIElement;
  menu: HTMLMenuElement;
  meta: HTMLMetaElement;
  meter: HTMLMeterElement;
  ol: HTMLOListElement;
  optgroup: HTMLOptGroupElement;
  option: HTMLOptionElement;
  output: HTMLOutputElement;
  p: HTMLParagraphElement;
  pre: HTMLPreElement;
  progress: HTMLProgressElement;
  script: HTMLScriptElement;
  select: HTMLSelectElement;
  slot: HTMLSlotElement;
  span: HTMLSpanElement;
  style: HTMLStyleElement;
  summary: HTMLSummaryElement;
  table: HTMLTableElement;
  tbody: HTMLTableSectionElement;
  td: HTMLTableCellElement;
  template: HTMLTemplateElement;
  textarea: HTMLTextAreaElement;
  tfoot: HTMLTableSectionElement;
  th: HTMLTableCellElement;
  thead: HTMLTableSectionElement;
  time: HTMLTimeElement;
  title: HTMLTitleElement;
  tr: HTMLTableRowElement;
  ul: HTMLUListElement;
  video: HTMLMediaElement;
}

// ---------------------------------------------------------------------------
// Custom elements

/** A class that makes an element, as customElements.define() registers it. */
export type CustomElementConstructor = new () => HTMLElement;

/** The callbacks a custom element's class offers. A class may have any of them. */
export interface CustomElementCallbacks {
  connectedCallback?(): void;
  disconnectedCallback?(): void;
  attributeChangedCallback?(name: string, oldValue: string | null, value: string | null): void;
}

/** What an element's class offers, recorded when the element became a custom element. */
interface CustomElementState {
  ctor: CustomElementConstructor;
  connected: boolean;
  disconnected: boolean;
  attributeChanged: boolean;
}

/** The tags the HTML and SVG specs keep out of a registry, even with a dash in the name. */
const RESERVED_TAGS = new Set([
  "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri",
  "font-face-format", "font-face-name", "missing-glyph",
]);

/** How many tags are defined. Tree edits walk for custom elements only once one exists. */
let CUSTOM_DEFS = 0;

/**
 * The registry behind `customElements`: a class per tag name, and the elements of those tags are
 * instances of it.
 *
 * A class is held as a value here, and scriptc can't read a class's statics through a value
 * (see docs/compiler-limitations.md), so `observedAttributes` can't be honored: the registry calls
 * attributeChangedCallback for every attribute change instead, and the element's own method
 * decides what matters. docs/supported.md says so.
 */
export class CustomElementRegistry {
  get [Symbol.toStringTag](): string { return "CustomElementRegistry"; }
  private defs: Map<string, CustomElementConstructor> = new Map();
  /** The resolvers waiting on each undefined tag, for whenDefined(). */
  private waiting: Map<string, Array<(ctor: CustomElementConstructor) => void>> = new Map();

  /**
   * Registers `ctor` for `name` and upgrades the elements of that name already in the tree. The
   * registry makes each element with `new ctor()`, so a component class takes no constructor
   * arguments, as HTMLElement does.
   */
  define(name: string, ctor: CustomElementConstructor, options?: { extends?: string }): void {
    if (!isCustomElementName(name)) {
      throw new Error(`SyntaxError: '${name}' is not a valid custom element name`);
    }
    // Customized built-in elements (the `extends` option) aren't supported; see supported.md.
    void options;
    if (this.defs.has(name)) {
      throw new Error(`NotSupportedError: '${name}' is already defined`);
    }
    this.defs.set(name, ctor);
    CUSTOM_DEFS++;
    const waiting = this.waiting.get(name);
    if (waiting !== undefined) {
      this.waiting.delete(name);
      for (const resolve of waiting) resolve(ctor);
    }
    // The elements of the name that are already in the tree become instances of the class now.
    this.upgrade(document.documentElement);
  }

  get(name: string): CustomElementConstructor | undefined {
    return this.defs.get(name);
  }

  /** The class for `name`, in a promise that settles when the name is defined. */
  whenDefined(name: string): Promise<CustomElementConstructor> {
    if (!isCustomElementName(name)) {
      throw new Error(`SyntaxError: '${name}' is not a valid custom element name`);
    }
    const ctor = this.defs.get(name);
    if (ctor !== undefined) {
      // A promise that is already resolved. Promise.resolve(value) has no lowering yet (#15).
      return new Promise<CustomElementConstructor>((resolve) => {
        resolve(ctor);
      });
    }
    return new Promise<CustomElementConstructor>((resolve) => {
      const list = this.waiting.get(name);
      if (list === undefined) this.waiting.set(name, [resolve]);
      else list.push(resolve);
    });
  }

  /**
   * Upgrades the defined elements under `root` now, instead of when they are inserted. A detached
   * root of its own is upgraded when it is inserted: an upgrade replaces the element with a new
   * one of the class (the base constructor can't return the existing element yet, #16), which
   * needs a parent to take its place. Its children are upgraded either way.
   */
  upgrade(root: Node): void {
    const upgraded = upgradeSubtree(root);
    for (const el of upgraded) if (el.isConnected) fireConnected(el);
    invalidateStyle();
  }
}

/** A custom element name: lowercase ASCII, a letter first, and a dash somewhere. */
function isCustomElementName(name: string): boolean {
  if (name === "" || RESERVED_TAGS.has(name)) return false;
  if (!/^[a-z]/.test(name) || name.indexOf("-") < 0) return false;
  return /^[a-z][a-z0-9._·-]*$/.test(name);
}

export const customElements = new CustomElementRegistry();

/** The class defined for a tag, or null when the tag isn't a custom element. */
function customConstructor(tag: string): CustomElementConstructor | null {
  const ctor = customElements.get(tag);
  return ctor === undefined ? null : ctor;
}

/** Records which callbacks an element's class offers, so the mutation paths can find them. */
function noteHooks(el: Element, ctor: CustomElementConstructor): void {
  const callbacks = el as unknown as CustomElementCallbacks;
  el.hooks = {
    ctor,
    connected: typeof callbacks.connectedCallback === "function",
    disconnected: typeof callbacks.disconnectedCallback === "function",
    attributeChanged: typeof callbacks.attributeChangedCallback === "function",
  };
}

/**
 * Makes a new element of the class defined for `tag`, outside a creation context: the class's
 * constructor runs with no arguments, and the tag is given here. Null when the tag isn't defined,
 * or when the class didn't build an element.
 */
/** The tag whose class is being constructed, so a constructor's calls can tell which element it is. */
let constructingTag = "";

function constructCustom(tag: string): HTMLElement | null {
  const ctor = customConstructor(tag);
  if (ctor === null) return null;
  // A class can't know which tag it was defined for until after it is made, but its constructor
  // may ask (attachInternals does): the name it is being built for is here while it runs.
  constructingTag = tag;
  const made = new ctor();
  constructingTag = "";
  if (!(made instanceof HTMLElement)) return null;
  // A class can't know which tag it was defined for; the caller knows the name.
  made.localName = tag;
  made.nodeName = tag.toUpperCase();
  made.tagName = tag.toUpperCase();
  noteHooks(made, ctor);
  return made;
}

/**
 * Turns `el` into an instance of `ctor`: a new element of the class takes the old element's
 * attributes, style, listeners and children, and its place in the tree.
 *
 * A browser keeps the same node through an upgrade; that needs a base constructor that can
 * return the existing instance, which scriptc refuses (#16). Here the element is replaced by the
 * new one, so the tree is right and a reference a script kept to the old element is stale.
 * docs/supported.md says so.
 */
function upgradeOne(el: Element, ctor: CustomElementConstructor): Element | null {
  // The upgrade's constructor runs before the element is told its tag, as a creation's does.
  constructingTag = el.localName;
  const made = new ctor();
  constructingTag = "";
  if (!(made instanceof HTMLElement)) return null;
  made.localName = el.localName;
  made.nodeName = el.nodeName;
  made.tagName = el.tagName;
  made.namespaceURI = el.namespaceURI;
  // The element being replaced is the truth about its attributes, style and content, in the order
  // it got them: the slot copies below and the order `attributes` lists them in.
  for (const [name, value] of el.attrMap) made.attrMap.set(name, value);
  if (el.nsAttrs !== null) {
    made.nsAttrs = new Map();
    for (const [key, attr] of el.nsAttrs) {
      made.nsAttrs.set(key, new Attr(attr.name, attr.value, made, attr.namespaceURI, attr.prefix, attr.localName));
    }
  }
  made.copyAttributeOrder(el);
  made.id = el.id;
  made.classList.setValue(el.classList.value);
  if (el.styleDecl !== null && el.styleDecl.present) made.setStyleText(el.styleDecl.cssText);
  made.hiddenFlag = el.hiddenFlag;
  made.imagePath = el.imagePath;
  made.dynamic = el.dynamic;
  made.rulesStale = el.rulesStale;
  made.inlineDefault = el.inlineDefault;
  made.rules = el.rules;
  made.sensitiveStates = el.sensitiveStates;
  made.listeners = el.listeners;
  made.ownText = el.ownText;
  made.beforePseudo = el.beforePseudo;
  made.afterPseudo = el.afterPseudo;
  made.markerPseudo = el.markerPseudo;
  made.markerRules = el.markerRules;
  for (const k of el.kids) k.parentNode = made;
  made.kids = el.kids;
  el.kids = [];
  const parent = el.parentNode;
  if (parent !== null) {
    const i = parent.kids.indexOf(el);
    if (i >= 0) parent.kids[i] = made;
    made.parentNode = parent;
    el.parentNode = null;
  }
  noteHooks(made, ctor);
  // A browser reports each attribute the element already has to the class that takes it over.
  for (const attr of made.attributes) notifyAttribute(made, attr.name, null);
  return made;
}

/**
 * Upgrades the defined elements in `node`'s subtree, in tree order, and returns the elements
 * that became custom elements so the caller can report them connected.
 */
function upgradeSubtree(node: Node): Element[] {
  const upgraded: Element[] = [];
  upgradeInto(node, upgraded);
  return upgraded;
}

function upgradeInto(node: Node, upgraded: Element[]): void {
  if (node.isElementNode && node.pseudoKind === P.PE_NONE) {
    const el = node as Element;
    // An element with no parent has nowhere to put its replacement; it waits for an insertion.
    if (el.hooks === null && el.parentNode !== null) {
      const ctor = customConstructor(el.localName);
      if (ctor !== null) {
        const made = upgradeOne(el, ctor);
        if (made !== null) {
          upgraded.push(made);
          upgradeInto(made, upgraded);
          return;
        }
      }
    }
  }
  for (const c of node.kids.slice()) {
    if (c.pseudoKind === P.PE_NONE) upgradeInto(c, upgraded);
  }
}

/** Calls connectedCallback on the custom elements in `node`'s subtree that are in the document. */
function connectedSubtree(node: Node): void {
  if (node.isElementNode && node.pseudoKind === P.PE_NONE && node.isConnected) fireConnected(node as Element);
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) connectedSubtree(c);
}

/** Calls disconnectedCallback on the custom elements in a subtree that just left the document. */
function disconnectedSubtree(node: Node): void {
  const el = node.isElementNode && node.pseudoKind === P.PE_NONE ? node as Element : null;
  if (el !== null && el.hooks !== null && el.hooks.disconnected) {
    const callbacks = el as unknown as CustomElementCallbacks;
    if (typeof callbacks.disconnectedCallback === "function") callbacks.disconnectedCallback();
  }
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) disconnectedSubtree(c);
}

/** Calls an element's connectedCallback if it has one. */
function fireConnected(el: Element): void {
  if (el.hooks === null || !el.hooks.connected) return;
  const callbacks = el as unknown as CustomElementCallbacks;
  if (typeof callbacks.connectedCallback === "function") callbacks.connectedCallback();
}

/** Reports an attribute change to the element's class, when it has an attribute callback. */
function notifyAttribute(el: Element, name: string, old: string | null): void {
  if (el.hooks === null || !el.hooks.attributeChanged) return;
  const value = el.getAttribute(name);
  if (value === old) return;
  const callbacks = el as unknown as CustomElementCallbacks;
  if (typeof callbacks.attributeChangedCallback === "function") {
    callbacks.attributeChangedCallback(name, old, value);
  }
}

/**
 * A new element for a tag name, as the class that tag names. The compiler's tree, markup
 * parsing, createElement and cloning all make their elements here, so every element in an app
 * is an instance of its own class.
 */
/** An element of no class of its own: a plain HTMLElement, set up through the HTML init step. */
function newPlainElement(tag: string, id: string, text: string, rules: readonly number[], states: number, inline: boolean): HTMLElement {
  const el = new HTMLElement();
  el.initEl(tag, id, text, rules, states, inline);
  return el;
}

export function newElementFor(tag: string, id: string, text: string, rules: readonly number[],
  states: number, inline: boolean): HTMLElement {
  if (tag === "a") return new HTMLAnchorElement(id, text, rules, states, inline);
  if (tag === "area") return new HTMLAreaElement(id, text, rules, states, inline);
  if (tag === "base") return new HTMLBaseElement(id, text, rules, states, inline);
  if (tag === "body") return new HTMLBodyElement(id, text, rules, states, inline);
  if (tag === "br") return new HTMLBRElement(id, text, rules, states, inline);
  if (tag === "button") return new HTMLButtonElement(id, text, rules, states, inline);
  if (tag === "canvas") return new HTMLCanvasElement(id, rules, states);
  if (tag === "caption") return new HTMLTableCaptionElement(id, text, rules, states, inline);
  if (tag === "col") return new HTMLTableColElement("col", id, text, rules, states, inline);
  if (tag === "colgroup") return new HTMLTableColElement("colgroup", id, text, rules, states, inline);
  if (tag === "datalist") return new HTMLDataListElement(id, text, rules, states, inline);
  if (tag === "details") return new HTMLDetailsElement(id, text, rules, states, inline);
  if (tag === "dialog") return new HTMLDialogElement(id, text, rules, states, inline);
  if (tag === "div") return new HTMLDivElement(id, text, rules, states, inline);
  if (tag === "fieldset") return new HTMLFieldSetElement(id, text, rules, states, inline);
  if (tag === "form") return new HTMLFormElement(id, text, rules, states, inline);
  if (tag === "h1" || tag === "h2" || tag === "h3" || tag === "h4" || tag === "h5" || tag === "h6") {
    return new HTMLHeadingElement(tag, id, text, rules, states, inline);
  }
  if (tag === "head") return new HTMLHeadElement(id, text, rules, states, inline);
  if (tag === "html") return new HTMLHtmlElement(id, text, rules, states, inline);
  if (tag === "iframe") return new HTMLIFrameElement(id, text, rules, states, inline);
  if (tag === "img") return new HTMLImageElement(id, rules, states);
  if (tag === "input") return new HTMLInputElement(id, rules, states);
  if (tag === "label") return new HTMLLabelElement(id, text, rules, states, inline);
  if (tag === "legend") return new HTMLLegendElement(id, text, rules, states, inline);
  if (tag === "li") return new HTMLLIElement(id, text, rules, states, inline);
  if (tag === "menu") return new HTMLMenuElement(id, text, rules, states, inline);
  if (tag === "meta") return new HTMLMetaElement(id, text, rules, states, inline);
  if (tag === "meter") return new HTMLMeterElement(id, text, rules, states, inline);
  if (tag === "ol") return new HTMLOListElement(id, text, rules, states, inline);
  if (tag === "optgroup") return new HTMLOptGroupElement(id, text, rules, states, inline);
  if (tag === "option") return new HTMLOptionElement(id, text, rules, states, inline);
  if (tag === "output") return new HTMLOutputElement(id, text, rules, states, inline);
  if (tag === "p") return new HTMLParagraphElement(id, text, rules, states, inline);
  if (tag === "pre") return new HTMLPreElement(id, text, rules, states, inline);
  if (tag === "progress") return new HTMLProgressElement(id, text, rules, states, inline);
  if (tag === "script") return new HTMLScriptElement(id, text, rules, states, inline);
  if (tag === "select") return new HTMLSelectElement(id, text, rules, states, inline);
  if (tag === "slot") return new HTMLSlotElement(id, text, rules, states, inline);
  if (tag === "span") return new HTMLSpanElement(id, text, rules, states, inline);
  if (tag === "style") return new HTMLStyleElement(id, text, rules, states, inline);
  if (tag === "summary") return new HTMLSummaryElement(id, text, rules, states, inline);
  if (tag === "table") return new HTMLTableElement(id, text, rules, states, inline);
  if (tag === "tbody" || tag === "thead" || tag === "tfoot") {
    return new HTMLTableSectionElement(tag, id, text, rules, states, inline);
  }
  if (tag === "td" || tag === "th") return new HTMLTableCellElement(tag, id, text, rules, states, inline);
  if (tag === "template") {
    // A template's text is its content's, not the element's own.
    const el = new HTMLTemplateElement(id, rules, states);
    if (text !== "") el.content.appendChild(new Text(text));
    return el;
  }
  if (tag === "textarea") return new HTMLTextAreaElement(id, text, rules, states, inline);
  if (tag === "time") return new HTMLTimeElement(id, text, rules, states, inline);
  if (tag === "title") return new HTMLTitleElement(id, text, rules, states, inline);
  if (tag === "tr") return new HTMLTableRowElement(id, text, rules, states, inline);
  if (tag === "ul") return new HTMLUListElement(id, text, rules, states, inline);
  if (tag === "audio") return new HTMLAudioElement(id, text, rules, states, inline);
  if (tag === "video") return new HTMLVideoElement(id, text, rules, states, inline);
  if (tag === "data") return new HTMLDataElement(id, text, rules, states, inline);
  if (tag === "dir") return new HTMLDirectoryElement(id, text, rules, states, inline);
  if (tag === "dl") return new HTMLDListElement(id, text, rules, states, inline);
  if (tag === "embed") return new HTMLEmbedElement(id, text, rules, states, inline);
  if (tag === "font") return new HTMLFontElement(id, text, rules, states, inline);
  if (tag === "frame") return new HTMLFrameElement(id, text, rules, states, inline);
  if (tag === "frameset") return new HTMLFrameSetElement(id, text, rules, states, inline);
  if (tag === "hr") return new HTMLHRElement(id, text, rules, states, inline);
  if (tag === "link") return new HTMLLinkElement(id, text, rules, states, inline);
  if (tag === "map") return new HTMLMapElement(id, text, rules, states, inline);
  if (tag === "del" || tag === "ins") return new HTMLModElement(tag, id, text, rules, states, inline);
  if (tag === "object") return new HTMLObjectElement(id, text, rules, states, inline);
  if (tag === "param") return new HTMLParamElement(id, text, rules, states, inline);
  if (tag === "q" || tag === "blockquote") return new HTMLQuoteElement(tag, id, text, rules, states, inline);
  if (tag === "source") return new HTMLSourceElement(id, text, rules, states, inline);
  if (tag === "track") return new HTMLTrackElement(id, text, rules, states, inline);
  // An unknown tag makes an unknown element; a name with a dash is a custom element's until one
  // is defined, and the tags HTML has always had stay plain HTMLElement.
  if (tag.indexOf("-") >= 0 || KNOWN_PLAIN_TAGS.indexOf(tag) >= 0) {
    return newPlainElement(tag, id, text, rules, states, inline);
  }
  return new HTMLUnknownElement(tag, id, text, rules, states, inline);
}

/** The tags whose interface is HTMLElement itself: all that HTML names and has no class for. */
const KNOWN_PLAIN_TAGS: readonly string[] = ("abbr acronym address article aside b bdi bdo bgsound big center " +
  "cite code dd dfn dt figcaption figure footer header hgroup i isindex kbd main mark marquee nav nobr " +
  "noframes noscript rp rt rtc ruby s samp section small spacer strike sub summary sup tt u var wbr xmp").split(" ");

/** The options focus() and focusVisible() take. */
export interface FocusOptions {
  preventScroll?: boolean;
  focusVisible?: boolean;
}

/** Whether a node holds a child that isn't a generated box. A style carrier or a generated box
 *  is not part of the element's content, so it neither keeps text from becoming a child nor
 *  makes the element one a script can walk into. */
export function hasRealChild(node: Node): boolean {
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) return true;
  return false;
}

/** Bumped whenever a `lang` attribute or the tree's shape changes, which is what can change the
 *  language an element inherits; langOf() memoizes its answer against it. */
let langVersion = 0;

/** How many shadow trees the page has made. With one, a node's slot can move it under a different
 *  parent in the flat tree, so a moved node's language cache can go stale in ways the DOM walk
 *  doesn't show; without one, only the nodes that moved can change language. */
let shadowTrees = 0;

/** Drops the cached language of a subtree, for nodes whose parent changed. */
function dropLangCache(n: Node): void {
  n.langVer = -1;
  for (const c of n.kids) dropLangCache(c);
}

/** True when no selector or table fixup can see that a text run was attached to `parent`, so the
 *  run can be styled on its own instead of a pass over the page. */
function textRunStylesAlone(parent: Node): boolean {
  if (dirty.style) return false;
  if (textDataMovesStyle(parent)) return false;
  return !isTablePart(parent);
}

/** Styles a text run a script just attached against its parent, when nothing else can see it. */
function styleInsertedText(parent: Node, node: Node): boolean {
  if (!node.isTextNode || !textRunStylesAlone(parent)) return false;
  node.layoutText = node.ownText;
  computeStyles(node, parent);
  // The parent lays its content out again; the damage is the run that arrived, which had no
  // pixels before, not the parent's whole span.
  invalidateLayout(parent, node, true);
  return true;
}

/** True when a box of the table kind needs the table fixup around its text, which only a pass
 *  over the page can lay out. */
function isTablePart(el: Node): boolean {
  switch (el.localName) {
    case "table": case "thead": case "tbody": case "tfoot": case "tr":
    case "td": case "th": case "caption": case "colgroup": case "col":
      return true;
  }
  return false;
}

/** Styles an element a script appended at the end of a parent, on its own, when nothing else on
 *  the page can see it: the new subtree is the only thing whose cascade can have moved. */
function styleAppendedBox(parent: Node, node: Node): boolean {
  if (node.nodeType !== 1 || dirty.style) return false;
  if (isTablePart(parent) || isTablePart(node)) return false;
  if (textDataMovesStyle(parent)) return false;
  // A scroll container makes one marker box per child, so a new child moves them.
  if (parent.sv[P.P_SCROLL_MARKER_GROUP] !== P.SG_NONE) return false;
  if (!appendedSubtreeStylesAlone()) return false;
  computeStyles(node, parent);
  invalidateLayout(parent, node, true);
  return true;
}

/**
 * True when changing the data of a text run under `parent` can move a computed value: a flex,
 * grid or lanes container decides whether a whitespace-only run is rendered from the run's text,
 * and a drop cap (a floated ::first-letter) takes its letter out of the run it belongs to. Every
 * other text change leaves the cascade as it was and needs only line breaking.
 */
function textDataMovesStyle(parent: Node): boolean {
  // An :empty condition, a :has() argument or a counter reads the text below an element, so an
  // edit inside it can change what a selector matches.
  if (textRunDependence.affectSelectors) return true;
  // A display: contents wrapper generates no box, so the flex, grid or lanes container that
  // decides a whitespace-only run's display is the nearest ancestor that does.
  let box: Node | null = parent;
  while (box !== null && box.sv[P.P_DISPLAY] === P.D_CONTENTS) box = box.parentElement;
  const d = box === null ? P.D_NONE : box.sv[P.P_DISPLAY];
  if (d === P.D_FLEX || d === P.D_INLINE_FLEX || d === P.D_GRID || d === P.D_INLINE_GRID ||
    d === P.D_GRID_LANES || d === P.D_INLINE_GRID_LANES) return true;
  for (let a: Node | null = parent; a !== null; a = a.parentNode) {
    if (a.firstLetterPseudo !== null || a.firstLetterFloat !== null) return true;
    // `dir=auto` (and a <bdi>) takes its direction from the text below it, and :dir() sees that.
    if (a.nodeType === 1) {
      const el = a as Element;
      const dir = el.attrMap.get("dir");
      if ((dir !== undefined && dir.trim().toLowerCase() === "auto") || el.localName === "bdi") return true;
    }
  }
  return false;
}

/** The element's language: the nearest `lang` (or `xml:lang`) attribute up the tree, or "" when
 *  no ancestor names one. ::first-letter asks for it, since some languages write a letter with
 *  two characters. */
export function langOf(el: Node | null): string {
  if (el === null) return "";
  // Text runs ask for this on every font-key lookup, so the answer is kept on the node until an
  // attribute or tree change could have moved it.
  if (el.langVer === langVersion) return el.langVal;
  let n: Node | null = el;
  let val = "";
  while (n !== null) {
    if (n instanceof Element) {
      // An empty lang attribute says the language is unknown, and it overrides an ancestor's.
      const v = n.attrMap.get("lang");
      if (v !== undefined) { val = v; break; }
      // xml:lang names the language only in an XML document; in HTML it is an unknown attribute.
      if (document.xmlDocument) {
        const x = n.attrMap.get("xml:lang");
        if (x !== undefined) { val = x; break; }
      }
      // A slotted element's parent in the flat tree is the slot it was assigned to.
      if (shadowTrees > 0 && n.assignedSlot !== null) { n = n.assignedSlot; continue; }
    } else if (n instanceof ShadowRoot) {
      // A shadow tree's nodes inherit the language of the host they hang from.
      n = n.host;
      continue;
    }
    n = n.parentNode;
  }
  el.langVer = langVersion;
  el.langVal = val;
  return val;
}

/**
 * A node holding its own text becomes a parent: its text turns into a text child, in the place
 * the text holds in the element: after a marker and ::before, before ::after and the carriers.
 * An element that already holds a child of its own keeps its ownText as it is.
 */
export function materializeText(node: Node): void {
  if (node.nodeType !== 1 || node.ownText === "" || hasRealChild(node)) return;
  // The node firstChild and childNodes hand out for the element's own text is the one that
  // becomes its child, so a range or walker holding it keeps pointing at the text.
  let t = node.ownTextNode;
  if (t === null) {
    t = new Text(node.ownText);
    node.ownTextNode = t;
  }
  t.ownText = node.ownText;
  t.parentNode = node;
  let at = 0;
  while (at < node.kids.length &&
    (node.kids[at].pseudoKind === P.PE_MARKER || node.kids[at].pseudoKind === P.PE_BEFORE)) at++;
  node.kids.splice(at, 0, t);
  node.ownText = "";
  // The text now lives in a node of its own: the document's text runs name a different holder.
  textVersion.n++;
  // The box's children changed outside a child-list call, and layout reads the settled list.
  node.flat = null;
}

/** A text node. Its data is the text layout formats, so a change repaints the page. */
/**
 * The boxes a node's children stand for. A shadow host's content is the shadow tree, and each
 * <slot> in it stands for the light children assigned to it (or the slot's own fallback). Layout,
 * paint and hit testing ask this, never the node's DOM children.
 */
export function boxKids(node: Node): Node[] {
  const made = node.flat;
  if (made !== null) return made;
  const shadow = node.shadowTree();
  const source = shadow !== null ? shadow.kids : node.kids;
  const out: Node[] = [];
  for (const kid of source) {
    if (shadow !== null && kid.isElementNode && (kid as Element).localName === "slot") {
      const slotEl = kid as Element;
      const assigned = assignedOf(slotEl);
      // A manual assignment may name a node that isn't the host's child; it is not slotted there.
      const host = slotHost(slotEl);
      const slotted: Node[] = [];
      for (const n of assigned) if (host !== null && n.parentNode === host) slotted.push(n);
      if (slotEl.assignedSnapshot !== null && !sameNodes(slotEl.assignedSnapshot, assigned)) {
        slotEl.assignedSnapshot = assigned.slice();
        dispatch(trusted(new Event("slotchange")), slotEl);
      } else if (slotEl.assignedSnapshot === null) {
        slotEl.assignedSnapshot = assigned.slice();
      }
      if (slotted.length > 0) {
        for (const n of slotted) out.push(n);
        continue;
      }
      for (const n of kid.kids) out.push(n);
      continue;
    }
    out.push(kid);
  }
  node.flat = out;
  return out;
}

/** The shadow tree a node sits in, or null when it is in the document. */
function shadowRootOfNode(node: Node): ShadowRoot | null {
  let n: Node | null = node.parentNode;
  while (n !== null) {
    if (n instanceof ShadowRoot) return n;
    n = n.parentNode;
  }
  return null;
}

/** The element that hosts the shadow tree a slot sits in, or null for a slot in the light tree. */
function slotHost(slot: Element): Element | null {
  let n: Node | null = slot.parentNode;
  while (n !== null) {
    if (n instanceof ShadowRoot) return n.host;
    n = n.parentNode;
  }
  return null;
}

/** The light children a slot was given, in document order. */
export function slotAssignedNodes(slot: Element): Node[] {
  return assignedOf(slot);
}

/** Every <slot> in a shadow tree, in tree order. */
export function slotsIn(root: Node, out: Element[] = []): Element[] {
  for (const kid of root.kids) {
    if (!kid.isElementNode) continue;
    if ((kid as Element).localName === "slot") out.push(kid as Element);
    slotsIn(kid, out);
  }
  return out;
}

/** `assignedNodes({flatten: true})`: a slot among the given nodes stands for what it was given. */
function flattenAssigned(nodes: Node[], out: Node[]): void {
  for (const n of nodes) {
    if (n.isElementNode && (n as Element).localName === "slot") {
      const inner = assignedOf(n as Element);
      if (inner.length > 0) flattenAssigned(inner, out);
      else flattenAssigned(n.kids, out);
      continue;
    }
    out.push(n);
  }
}

/** Whether two node lists are the same nodes in the same order. */
function sameNodes(a: Node[], b: Node[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** The light children a slot takes, in document order: the ones naming it, or the default ones. */
function assignedOf(slot: Element): Node[] {
  const host = slotHost(slot);
  if (host === null) return [];
  if (slot instanceof HTMLSlotElement) {
    const root = shadowRootOfNode(slot);
    if (root !== null && root.slotAssignment === "manual") return (slot.manualAssigned ?? []).slice();
  }
  const name = slot.getAttribute("name") ?? "";
  const out: Node[] = [];
  for (const kid of host.kids) {
    if (kid.pseudoKind !== 0) continue;
    const kidName = kid.isElementNode ? (kid as Element).getAttribute("slot") ?? "" : "";
    if (kidName === name) out.push(kid);
  }
  return out;
}

export class Text extends Node {
  get [Symbol.toStringTag](): string { return "Text"; }
  constructor(data: string) {
    super("#text", data, [], 0, false);
  }
  // `data` is a DOMString, and scriptc gives a getter/setter pair one type (it refuses a pair
  // whose halves differ), so the pair is `any`: a renderer's number (a `{count}` child) is
  // converted, as in a browser, and null, marked LegacyNullToEmptyString, clears the node.
  get data(): any {
    return this.ownText;
  }
  set data(value: any) {
    this.setText(value === null ? "" : String(value));
  }
  get length(): number {
    return this.ownText.length;
  }
  get wholeText(): string {
    return this.ownText;
  }
  /** The text from `offset` for `count` characters, as substringData gives it. */
  substringData(...args: any[]): string {
    if (args.length < 2) throw new TypeError("Failed to execute 'substringData': 2 arguments required.");
    const len = this.ownText.length;
    const at = offsetIndex(args[0], len, "substringData");
    return this.ownText.substring(at, at + toUnsignedLong(args[1]));
  }
  /** Adds text to the end. */
  appendData(...args: any[]): void {
    if (args.length < 1) throw new TypeError("Failed to execute 'appendData': 1 argument required.");
    this.replaceData(this.ownText.length, 0, args[0]);
  }
  /** Puts text in at `offset`. */
  insertData(...args: any[]): void {
    if (args.length < 2) throw new TypeError("Failed to execute 'insertData': 2 arguments required.");
    this.replaceData(args[0], 0, args[1]);
  }
  /** Takes `count` characters out at `offset`. */
  deleteData(...args: any[]): void {
    if (args.length < 2) throw new TypeError("Failed to execute 'deleteData': 2 arguments required.");
    this.replaceData(args[0], args[1], "");
  }
  /**
   * Replaces `count` characters at `offset` with `data`: the one CharacterData mutation the
   * others are written in terms of. An offset past the end is an IndexSizeError, and a count
   * that runs past it is cut short, as in a browser.
   */
  replaceData(...args: any[]): void {
    if (args.length < 3) throw new TypeError("Failed to execute 'replaceData': 3 arguments required.");
    const text = this.ownText;
    const at = offsetIndex(args[0], text.length, "replaceData");
    let n = toUnsignedLong(args[1]);
    if (at + n > text.length) n = text.length - at;
    const addition = String(args[2]);
    moveLiveRanges(this, at, n, addition.length - n);
    this.setText(text.slice(0, at) + addition + text.slice(at + n));
  }
  /** Replaces this text and the contiguous text nodes around it with one text node. */
  replaceWholeText(data: any): Text {
    const text = data === null ? "" : String(data);
    const parent = this.parentNode;
    if (parent === null) return this;
    let first: Node = this;
    while (first.previousSibling !== null && first.previousSibling.isTextNode) first = first.previousSibling;
    let last: Node = this;
    while (last.nextSibling !== null && last.nextSibling.isTextNode) last = last.nextSibling;
    const made = new Text(text);
    made.dynamic = this.dynamic;
    parent.insertBefore(made, first);
    let n: Node | null = first;
    while (n !== null) {
      const next: Node | null = n.nextSibling;
      parent.removeChild(n);
      if (n === last) break;
      n = next;
    }
    return made;
  }
  /** Splits off the text from `offset` on into a new sibling node, as CharacterData.splitText. */
  splitText(offset: number = 0): Text {
    const at = Math.floor(offset);
    if (at < 0 || at > this.ownText.length) {
      throw new Error("IndexSizeError: Failed to execute 'splitText' on 'Text': The offset " + at + " is larger than the Text node's length.");
    }
    const parent = this.parentNode;
    if (parent === null) throw new Error("NoModificationAllowedError: Failed to execute 'splitText' on 'Text': The node is read-only.");
    const rest = new Text(this.ownText.slice(at));
    rest.dynamic = this.dynamic;
    this.setText(this.ownText.slice(0, at));
    parent.insertBefore(rest, this.nextSibling);
    return rest;
  }
}

/**
 * A CDATA section: text that isn't markup, in an XML document. It reads as text (a browser's
 * CDATASection extends Text) but reports its own node type.
 */
export class CDATASection extends Text {
  get [Symbol.toStringTag](): string { return "CDATASection"; }
  constructor(data: string) {
    super(data);
    this.nodeType = 4;
    this.nodeName = "#cdata-section";
    this.tagName = "#cdata-section";
  }
}

/** A processing instruction: a target and its data, which no renderer draws. */
/** XML's NameStartChar production. */
function piNameStartChar(c: number): boolean {
  return c === 0x3a || c === 0x5f || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) ||
    (c >= 0xc0 && c <= 0xd6) || (c >= 0xd8 && c <= 0xf6) || (c >= 0xf8 && c <= 0x2ff) ||
    (c >= 0x370 && c <= 0x37d) || (c >= 0x37f && c <= 0x1fff) || (c >= 0x200c && c <= 0x200d) ||
    (c >= 0x2070 && c <= 0x218f) || (c >= 0x2c00 && c <= 0x2fef) || (c >= 0x3001 && c <= 0xd7ff) ||
    (c >= 0xf900 && c <= 0xfdcf) || (c >= 0xfdf0 && c <= 0xfffd) || (c >= 0x10000 && c <= 0xeffff);
}

/** XML's NameChar production. */
function piNameChar(c: number): boolean {
  return piNameStartChar(c) || c === 0x2d || c === 0x2e || (c >= 0x30 && c <= 0x39) || c === 0xb7 ||
    (c >= 0x300 && c <= 0x36f) || (c >= 0x203f && c <= 0x2040);
}

/** Whether a string matches XML's Name production. */
function piValidName(name: string): boolean {
  if (name === "") return false;
  const first = name.codePointAt(0)!;
  if (!piNameStartChar(first)) return false;
  let i = first > 0xffff ? 2 : 1;
  while (i < name.length) {
    const c = name.codePointAt(i)!;
    if (!piNameChar(c)) return false;
    i += c > 0xffff ? 2 : 1;
  }
  return true;
}

/** XML's Char production: the characters a value may hold. */
function isXmlChar(c: number): boolean {
  return c === 0x9 || c === 0xa || c === 0xd || (c >= 0x20 && c <= 0xd7ff) ||
    (c >= 0xe000 && c <= 0xfffd) || (c >= 0x10000 && c <= 0x10ffff);
}

function validXmlChars(text: string): boolean {
  let i = 0;
  while (i < text.length) {
    const c = text.codePointAt(i)!;
    if (!isXmlChar(c)) return false;
    i += c > 0xffff ? 2 : 1;
  }
  return true;
}

function piSpace(c: string | undefined): boolean {
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

/** Escapes a value the way a processing instruction's data carries it. */
function escapePseudoAttribute(value: string): string {
  return value.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;").split('"').join("&quot;");
}

/** One XML Reference at `at` (which holds '&'), or null when it isn't one. */
function piReference(text: string, at: number): { value: string; end: number } | null {
  const semi = text.indexOf(";", at + 1);
  if (semi < 0) return null;
  const body = text.slice(at + 1, semi);
  const named: { [k: string]: string } = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  const known = named[body];
  if (known !== undefined) return { value: known, end: semi + 1 };
  if (body.length > 1 && body[0] === "#") {
    let code = NaN;
    if (body[1] === "x" || body[1] === "X") {
      if (!/^#x[0-9A-Fa-f]+$/.test(body)) return null;
      code = parseInt(body.slice(2), 16);
    } else {
      if (!/^#[0-9]+$/.test(body)) return null;
      code = parseInt(body.slice(1), 10);
    }
    if (!Number.isFinite(code) || !isXmlChar(code)) return null;
    return { value: String.fromCodePoint(code), end: semi + 1 };
  }
  return null;
}

/**
 * Parses a processing instruction's data as PseudoAtts: an optional run of spaces, then
 * Name, `=`, a quoted value, more pairs separated by spaces, and an optional run of spaces.
 * Returns null when the data isn't that, so the instruction has no attributes at all.
 */
function parsePseudoAtts(text: string): string[][] | null {
  let i = 0;
  while (piSpace(text[i])) i++;
  const out: string[][] = [];
  const seen = new Set<string>();
  while (i < text.length) {
    const nameStart = i;
    let c = text.codePointAt(i)!;
    if (!piNameStartChar(c)) return null;
    i += c > 0xffff ? 2 : 1;
    while (i < text.length) {
      c = text.codePointAt(i)!;
      if (!piNameChar(c)) break;
      i += c > 0xffff ? 2 : 1;
    }
    const name = text.slice(nameStart, i);
    if (seen.has(name)) return null;
    seen.add(name);
    while (piSpace(text[i])) i++;
    if (text[i] !== "=") return null;
    i++;
    while (piSpace(text[i])) i++;
    const quote = text[i];
    if (quote !== '"' && quote !== "'") return null;
    i++;
    let value = "";
    let closed = false;
    while (i < text.length) {
      const ch = text[i];
      if (ch === quote) { i++; closed = true; break; }
      if (ch === "&") {
        const ref = piReference(text, i);
        if (ref === null) return null;
        value += ref.value;
        i = ref.end;
        continue;
      }
      if (ch === "<") return null;
      const code = text.codePointAt(i)!;
      if (!isXmlChar(code)) return null;
      value += text.slice(i, i + (code > 0xffff ? 2 : 1));
      i += code > 0xffff ? 2 : 1;
    }
    if (!closed) return null;
    out.push([name, value]);
    if (i === text.length) break;
    if (!piSpace(text[i])) return null;
    while (piSpace(text[i])) i++;
  }
  return out;
}

export class ProcessingInstruction extends Node {
  get [Symbol.toStringTag](): string { return "ProcessingInstruction"; }
  readonly target: string;

  constructor(target: string, data: string) {
    super("#processing-instruction", data, [], 0, false);
    this.target = target;
    this.nodeType = 7;
    this.nodeName = target;
    this.tagName = target;
  }
  get data(): any {
    return this.ownText;
  }
  set data(value: any) {
    this.setText(value === null ? "" : String(value));
  }
  get length(): number {
    return this.ownText.length;
  }
  /** The data from `offset` for `count` characters, as substringData gives it. */
  substringData(...args: any[]): string {
    if (args.length < 2) throw new TypeError("Failed to execute 'substringData': 2 arguments required.");
    const at = offsetIndex(args[0], this.ownText.length, "substringData");
    return this.ownText.substring(at, at + toUnsignedLong(args[1]));
  }
  appendData(...args: any[]): void {
    if (args.length < 1) throw new TypeError("Failed to execute 'appendData': 1 argument required.");
    this.replaceData(this.ownText.length, 0, args[0]);
  }
  insertData(...args: any[]): void {
    if (args.length < 2) throw new TypeError("Failed to execute 'insertData': 2 arguments required.");
    this.replaceData(args[0], 0, args[1]);
  }
  deleteData(...args: any[]): void {
    if (args.length < 2) throw new TypeError("Failed to execute 'deleteData': 2 arguments required.");
    this.replaceData(args[0], args[1], "");
  }
  replaceData(...args: any[]): void {
    if (args.length < 3) throw new TypeError("Failed to execute 'replaceData': 3 arguments required.");
    const text = this.ownText;
    const at = offsetIndex(args[0], text.length, "replaceData");
    let n = toUnsignedLong(args[1]);
    if (at + n > text.length) n = text.length - at;
    const addition = String(args[2]);
    moveLiveRanges(this, at, n, addition.length - n);
    this.setText(text.slice(0, at) + addition + text.slice(at + n));
  }

  // --- Attributes (the declarative-partial-updates extension) ------------------
  //
  // A processing instruction's data may be a list of quoted attributes; the node then answers
  // the attribute methods with them. The grammar is XML-stylesheet's PseudoAtts: Name, then
  // `=`, then a quoted value, with the whole string matching and no name twice. Anything else
  // leaves the instruction without attributes, so `a=b x="yy"` has none while `a="b" x="yy"`
  // has two.

  private attrPairs(): string[][] | null {
    return parsePseudoAtts(this.ownText);
  }

  hasAttributes(): boolean {
    const pairs = this.attrPairs();
    return pairs !== null && pairs.length > 0;
  }

  hasAttribute(name: any): boolean {
    return this.getAttribute(name) !== null;
  }

  getAttribute(name: any): string | null {
    const pairs = this.attrPairs();
    if (pairs === null) return null;
    const key = String(name);
    for (const pair of pairs) if (pair[0] === key) return pair[1];
    return null;
  }

  getAttributeNames(): string[] {
    const pairs = this.attrPairs();
    return pairs === null ? [] : pairs.map((pair) => pair[0]);
  }

  /** Sets an attribute and writes the list back into the data, in insertion order. */
  setAttribute(name: any, value: any): void {
    const key = String(name);
    if (!piValidName(key)) {
      throw new Error(`InvalidCharacterError: Failed to execute 'setAttribute' on 'ProcessingInstruction': '${key}' is not a valid attribute name.`);
    }
    const text = String(value);
    if (!validXmlChars(text)) {
      throw new Error("InvalidCharacterError: Failed to execute 'setAttribute' on 'ProcessingInstruction': the value contains a character XML does not allow.");
    }
    const pairs = this.attrPairs();
    const next: string[][] = pairs === null ? [] : pairs;
    for (const pair of next) {
      if (pair[0] === key) {
        pair[1] = text;
        this.writeAttrPairs(next);
        return;
      }
    }
    next.push([key, text]);
    this.writeAttrPairs(next);
  }

  removeAttribute(name: any): void {
    const pairs = this.attrPairs();
    if (pairs === null) return;
    const key = String(name);
    for (let i = 0; i < pairs.length; i++) {
      if (pairs[i][0] !== key) continue;
      pairs.splice(i, 1);
      this.writeAttrPairs(pairs);
      return;
    }
  }

  /** Adds or removes an attribute by name, as toggleAttribute does on an element. */
  toggleAttribute(name: any, force?: boolean): boolean {
    const key = String(name);
    if (!piValidName(key)) {
      throw new Error(`InvalidCharacterError: Failed to execute 'toggleAttribute' on 'ProcessingInstruction': '${key}' is not a valid attribute name.`);
    }
    const has = this.hasAttribute(key);
    const want = force === undefined ? !has : force;
    if (want && !has) this.setAttribute(key, "");
    else if (!want && has) this.removeAttribute(key);
    return want;
  }

  private writeAttrPairs(pairs: string[][]): void {
    let out = "";
    for (const pair of pairs) {
      if (out !== "") out += " ";
      out += pair[0] + '="' + escapePseudoAttribute(pair[1]) + '"';
    }
    // The update replaces the whole data, so a live range whose boundary is in it collapses.
    let r: Range | null = liveRangeHead;
    while (r !== null) {
      if (r.startContainer === this) r.startOffset = 0;
      if (r.endContainer === this) r.endOffset = 0;
      r = r.nextLive;
    }
    this.setText(out);
  }
  protected shallowClone(): Node {
    const copy = new ProcessingInstruction(this.target, this.ownText);
    copy.owner = this.owner;
    return copy;
  }
}

/** A document type declaration: its name and the identifiers it carries; nothing draws it. */
export class DocumentType extends Node {
  get [Symbol.toStringTag](): string { return "DocumentType"; }
  readonly name: string;
  readonly publicId: string;
  readonly systemId: string;

  constructor(name: string, publicId: string = "", systemId: string = "") {
    super("#doctype", "", [], 0, false);
    this.name = String(name);
    this.publicId = String(publicId);
    this.systemId = String(systemId);
    this.nodeName = this.name;
  }
  protected shallowClone(): Node {
    const copy = new DocumentType(this.name, this.publicId, this.systemId);
    copy.owner = this.owner;
    return copy;
  }
}

/** A comment node. It takes part in the tree but never draws or takes room. */
export class Comment extends Text {
  get [Symbol.toStringTag](): string { return "Comment"; }
  constructor(data: string) {
    super(data);
    this.nodeType = 8;
    this.nodeName = "#comment";
    this.tagName = "#comment";
  }
  /** As CharacterData.data is: one any-typed pair, converting what is stored. */
  get data(): any {
    return this.ownText;
  }
  set data(value: any) {
    this.setText(value === null ? "" : String(value));
  }
}

/** A fragment of a tree: inserting one inserts its children, leaving the fragment empty. */
export class DocumentFragment extends Node {
  get [Symbol.toStringTag](): string { return "DocumentFragment"; }
  constructor() {
    super("#document-fragment", "", [], 0, false);
  }
  /** The first descendant the selector matches; a fragment is its own :scope. */
  querySelector<T extends Element = Element>(selector: string): T | null {
    const sels = parseSelectorArg(selector, "querySelector", "DocumentFragment");
    return firstMatch(this, sels, null) as T | null;
  }
  /** Every descendant the selector matches, in tree order. */
  querySelectorAll<T extends Element = Element>(selector: string): T[] {
    const sels = parseSelectorArg(selector, "querySelectorAll", "DocumentFragment");
    const out: Element[] = [];
    collectMatches(this, sels, null, out);
    return out as T[];
  }
  /** The descendant with this id, as a fragment's getElementById finds it. */
  getElementById(id: string): Element | null {
    return findById(this, id);
  }
  /** The fragment's children as HTML text; setting it parses the text into new children. */
  get innerHTML(): string {
    return markupOfChildren(this);
  }
  set innerHTML(html: string) {
    this.replaceChildren(...parseFragment(String(html)));
  }
  /** Parses markup that may hold declarative shadow roots into this tree. */
  setHTMLUnsafe(html: string): void {
    const nodes = parseFragment(String(html));
    for (const n of nodes) adoptDeclarativeIn(n);
    this.replaceChildren(...nodes);
  }
  /** Serializes this tree, with the shadow roots the options name (or all serializable ones). */
  getHTML(options: GetHTMLOptions = {}): string {
    return markupOfChildren(this, options);
  }
}

/** CharacterData, the base of Text, Comment and a CDATA section: text nodes here are that base. */
export const CharacterData = Text;

/**
 * The root of an element's shadow tree (see Element.attachShadow): its children are the elements
 * the host renders, with the light children filling its slots; the class is what code that names a shadow
 * root, or checks `instanceof ShadowRoot`, refers to.
 */
export class ShadowRoot extends DocumentFragment {
  get [Symbol.toStringTag](): string { return "ShadowRoot"; }
  readonly host: Element;
  readonly mode: string;
  readonly delegatesFocus: boolean;
  /** "named" (the default) finds a slot by the light child's slot name; "manual" by assign(). */
  readonly slotAssignment: string;
  /** Whether getHTML() serializes this root by default, and whether cloneNode() copies it. */
  readonly clonable: boolean;
  readonly serializable: boolean;
  /** The constructed sheets this tree adopts; they apply to the tree and nothing else. */
  adoptedSheets: CSSStyleSheet[] = [];
  get adoptedStyleSheets(): CSSStyleSheet[] {
    return this.adoptedSheets.slice();
  }
  set adoptedStyleSheets(sheets: CSSStyleSheet[]) {
    this.adoptedSheets = sheets.slice();
    invalidateStyle();
  }
  activeElement: Element | null = null;

  constructor(host: Element, mode: string = "open", delegatesFocus: boolean = false, slotAssignment: string = "named",
    clonable: boolean = false, serializable: boolean = false) {
    super();
    this.host = host;
    this.mode = mode;
    this.delegatesFocus = delegatesFocus;
    this.slotAssignment = slotAssignment;
    this.clonable = clonable;
    this.serializable = serializable;
  }
}

/**
 * The node types a TreeWalker visits, as one bit per type (SHOW_ALL asks for every one), and what
 * a filter answers for a node: accept it, reject it and its subtree, or skip it but not its
 * children. A walker takes these from this object, as a browser's `NodeFilter` gives them.
 */
export const NodeFilter = {
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3,
  SHOW_ALL: 0xFFFFFFFF,
  SHOW_ELEMENT: 0x01,
  SHOW_ATTRIBUTE: 0x02,
  SHOW_TEXT: 0x04,
  SHOW_CDATA_SECTION: 0x08,
  // The legacy entity and notation types: no node makes them any more, but the constants stay.
  SHOW_ENTITY_REFERENCE: 0x10,
  SHOW_ENTITY: 0x20,
  SHOW_PROCESSING_INSTRUCTION: 0x40,
  SHOW_COMMENT: 0x80,
  SHOW_DOCUMENT: 0x100,
  SHOW_DOCUMENT_TYPE: 0x200,
  SHOW_DOCUMENT_FRAGMENT: 0x400,
  SHOW_NOTATION: 0x800,
};

/** A node filter: a function of the node, or an object whose acceptNode() is. */
export type NodeFilterLike = (node: Node) => number;
export interface NodeFilterObject {
  acceptNode(node: Node): number;
}

/**
 * document.createTreeWalker(): visits the nodes under a root in document order, skipping the
 * types `whatToShow` leaves out and whatever the filter rejects or skips. `currentNode` is where
 * the walk is; every method looks from there, as a browser's walker does.
 */
export class TreeWalker {
  get [Symbol.toStringTag](): string { return "TreeWalker"; }
  readonly root: Node;
  readonly whatToShow: number;
  readonly filter: NodeFilterLike | NodeFilterObject | null;
  private current: Node;
  /** Where the walk is; assigning a non-Node throws, as the DOM's currentNode does. */
  get currentNode(): Node {
    return this.current;
  }
  set currentNode(value: Node) {
    this.current = requireNode(value, "TreeWalker.currentNode");
  }

  constructor(root: Node, whatToShow: number = NodeFilter.SHOW_ALL,
    filter: NodeFilterLike | NodeFilterObject | null = null) {
    this.root = root;
    this.whatToShow = whatToShow;
    this.filter = filter;
    this.current = requireNode(root, "TreeWalker");
  }

  /** FILTER_ACCEPT, FILTER_SKIP or FILTER_REJECT for a node: its type, then the filter. */
  private accept(node: Node): number {
    this.settle(node);
    const bit = node.nodeType >= 1 && node.nodeType <= 12 ? 1 << (node.nodeType - 1) : 0;
    if ((this.whatToShow & bit) === 0) return NodeFilter.FILTER_SKIP;
    const filter = this.filter;
    if (filter === null) return NodeFilter.FILTER_ACCEPT;
    if (typeof filter === "function") return filter(node);
    return filter.acceptNode(node);
  }

  /**
   * An element's own text is a text child in the tree a walker visits, as in a browser, so an
   * element that still holds its text alone gives it a child before the walk reads its children.
   */
  private settle(node: Node): void {
    if (node.nodeType === 1 && !hasRealChild(node) && node.ownText !== "") {
      materializeText(node);
      invalidateStyle();
    }
  }

  /** The next node in document order after `currentNode`, skipping what the walker leaves out. */
  nextNode(): Node | null {
    let node: Node | null = this.currentNode;
    this.settle(node);
    let descend = true;
    while (node !== null) {
      if (descend && node.firstChild !== null) {
        node = node.firstChild;
      } else {
        // Up to the nearest ancestor with a following sibling inside the root.
        let up: Node | null = node;
        while (up !== null && up !== this.root && up.nextSibling === null) up = up.parentNode;
        if (up === null || up === this.root) return null;
        node = up.nextSibling;
      }
      if (node === null) return null;
      const result = this.accept(node);
      if (result === NodeFilter.FILTER_ACCEPT) {
        this.currentNode = node;
        return node;
      }
      // A rejected node's children are left out too; a skipped one's are visited.
      descend = result !== NodeFilter.FILTER_REJECT;
    }
    return null;
  }

  /** The previous node in document order before `currentNode`, as nextNode() walks backwards. */
  previousNode(): Node | null {
    let node: Node | null = this.currentNode;
    while (node !== null && node !== this.root) {
      let sibling: Node | null = node.previousSibling;
      while (sibling !== null) {
        node = sibling;
        let result = this.accept(node);
        // Descend to the deepest descendant the filter is willing to look at.
        while (result !== NodeFilter.FILTER_REJECT && node.lastChild !== null) {
          node = node.lastChild;
          result = this.accept(node);
        }
        if (result === NodeFilter.FILTER_ACCEPT) {
          this.currentNode = node;
          return node;
        }
        sibling = node.previousSibling;
      }
      node = node.parentNode;
      if (node === null) return null;
      // The root is the last node a walk backwards reaches, when the walker takes it.
      if (this.accept(node) === NodeFilter.FILTER_ACCEPT) {
        this.currentNode = node;
        return node;
      }
      if (node === this.root) return null;
    }
    return null;
  }

  /** The parent of `currentNode`, when it is inside the root and the walker accepts it. */
  parentNode(): Node | null {
    if (this.currentNode === this.root) return null;
    let node: Node | null = this.currentNode.parentNode;
    while (node !== null) {
      if (this.accept(node) === NodeFilter.FILTER_ACCEPT) {
        this.currentNode = node;
        return node;
      }
      if (node === this.root) return null;
      node = node.parentNode;
    }
    return null;
  }

  /** The first accepted node in `currentNode`'s subtree, walking through skipped nodes' children. */
  firstChild(): Node | null {
    return this.stepChild(true);
  }

  /** The last accepted node in `currentNode`'s subtree. */
  lastChild(): Node | null {
    return this.stepChild(false);
  }

  /** The next sibling of `currentNode`, the next node after it at the same level. */
  nextSibling(): Node | null {
    const current = this.currentNode;
    if (current === this.root) return null;
    const parent = current.parentNode;
    if (parent === null) return null;
    while (true) {
      const next = this.nextNode();
      if (next === null) {
        this.currentNode = current;
        return null;
      }
      if (next.parentNode === parent) return next;
      if (!parent.contains(next)) {
        this.currentNode = current;
        return null;
      }
    }
  }

  /** The previous sibling of `currentNode`, the last node before it at the same level. */
  previousSibling(): Node | null {
    const current = this.currentNode;
    if (current === this.root) return null;
    const parent = current.parentNode;
    if (parent === null) return null;
    while (true) {
      const prev = this.previousNode();
      if (prev === null) {
        this.currentNode = current;
        return null;
      }
      if (prev === parent) {
        this.currentNode = current;
        return null;
      }
      if (prev.parentNode === parent) return prev;
      if (!parent.contains(prev)) {
        this.currentNode = current;
        return null;
      }
    }
  }

  /** The first or last accepted node in the current node's subtree, through skipped children. */
  private stepChild(first: boolean): Node | null {
    const parent = this.currentNode;
    this.settle(parent);
    let node: Node | null = first ? parent.firstChild : parent.lastChild;
    while (node !== null) {
      const result = this.accept(node);
      if (result === NodeFilter.FILTER_ACCEPT) {
        this.currentNode = node;
        return node;
      }
      const child: Node | null = first ? node.firstChild : node.lastChild;
      if (result === NodeFilter.FILTER_SKIP && child !== null) {
        node = child;
        continue;
      }
      // This node is done; take the next one at this level, backing out of skipped parents.
      let next: Node | null = first ? node.nextSibling : node.previousSibling;
      while (next === null && node !== null && node !== parent) {
        node = node.parentNode;
        next = node === null || node === parent ? null : first ? node.nextSibling : node.previousSibling;
      }
      node = next;
    }
    return null;
  }
}

/**
 * document.createNodeIterator(): a cursor over the nodes under a root in document order. The
 * cursor sits before or after a reference node, so nextNode() and previousNode() walk the same
 * tree a walker does, one node at a time.
 */
export class NodeIterator {
  get [Symbol.toStringTag](): string { return "NodeIterator"; }
  readonly root: Node;
  readonly whatToShow: number;
  readonly filter: NodeFilterLike | NodeFilterObject | null;
  private ref: Node;
  private before: boolean;
  /** The node the cursor sits at; read-only, as the DOM's interface has it. */
  get referenceNode(): Node {
    return this.ref;
  }
  /** Whether the cursor sits before its reference node; read-only. */
  get pointerBeforeReferenceNode(): boolean {
    return this.before;
  }
  /** The node following the reference as it was last seen. A caller that removes the node it was
   *  given leaves that node without a parent, so the cursor needs to remember where it went. */
  private after: Node | null;

  constructor(root: Node, whatToShow: number = NodeFilter.SHOW_ALL,
    filter: NodeFilterLike | NodeFilterObject | null = null) {
    this.root = root;
    this.whatToShow = whatToShow;
    this.filter = filter;
    this.ref = requireNode(root, "NodeIterator");
    this.before = true;
    this.after = null;
  }

  /** FILTER_ACCEPT, FILTER_SKIP or FILTER_REJECT for a node: its type, then the filter. */
  private accept(node: Node): number {
    // An element's own text is a text child in the tree a cursor visits, as the walker above says.
    if (node.nodeType === 1 && !hasRealChild(node) && node.ownText !== "") {
      materializeText(node);
      invalidateStyle();
    }
    const bit = node.nodeType >= 1 && node.nodeType <= 12 ? 1 << (node.nodeType - 1) : 0;
    if ((this.whatToShow & bit) === 0) return NodeFilter.FILTER_SKIP;
    const filter = this.filter;
    if (filter === null) return NodeFilter.FILTER_ACCEPT;
    if (typeof filter === "function") return filter(node);
    return filter.acceptNode(node);
  }

  /** The node after `node` in tree order, staying inside the root's subtree. */
  private following(node: Node): Node | null {
    if (node.firstChild !== null) return node.firstChild;
    let up: Node | null = node;
    while (up !== null && up !== this.root && up.nextSibling === null) up = up.parentNode;
    if (up === null || up === this.root) return null;
    return up.nextSibling;
  }

  /** The node before `node` in tree order, staying inside the root's subtree. */
  private preceding(node: Node): Node | null {
    const prev = node.previousSibling;
    if (prev !== null) {
      let down: Node = prev;
      while (down.lastChild !== null) down = down.lastChild;
      return down;
    }
    const up = node.parentNode;
    return up === null || up === this.root ? null : up;
  }

  /** Whether `node` is still inside the root's subtree; a node the caller removed is not. */
  private withinRoot(node: Node): boolean {
    let n: Node | null = node;
    while (n !== null) {
      if (n === this.root) return true;
      n = n.parentNode;
    }
    return false;
  }

  /** The next accepted node in document order, or null at the end of the root's subtree. */
  nextNode(): Node | null {
    if (this.before) {
      this.before = false;
      const ref = this.ref;
      this.after = this.following(ref);
      if (this.accept(ref) === NodeFilter.FILTER_ACCEPT) return ref;
    }
    let node = this.withinRoot(this.ref) ? this.following(this.ref) : this.after;
    while (node !== null) {
      const next = this.following(node);
      if (this.accept(node) === NodeFilter.FILTER_ACCEPT) {
        this.ref = node;
        this.after = next;
        return node;
      }
      // A cursor takes no subtree: a rejected node's children are visited like a skipped one's.
      node = next;
    }
    return null;
  }

  /** The previous accepted node in document order, or null at the start of the root's subtree. */
  previousNode(): Node | null {
    if (!this.before) {
      this.before = true;
      if (this.accept(this.ref) === NodeFilter.FILTER_ACCEPT) return this.ref;
    }
    let node = this.preceding(this.ref);
    while (node !== null) {
      if (this.accept(node) === NodeFilter.FILTER_ACCEPT) {
        this.ref = node;
        return node;
      }
      node = this.preceding(node);
    }
    return null;
  }

  /** A cursor holds no state a caller can release, as the DOM says; the method stays for history. */
  detach(): void {}
}

/**
 * The node an event travels to from `node`: the slot a shadow tree took it into, when it was
 * assigned to one, or its parent. A shadow root hands the event to its host only when the event
 * is composed, which is what keeps an uncomposed event inside its tree.
 */
function eventParent(node: Node, target: Node, composed: boolean): Node | null {
  const slot = node.assignedSlot;
  if (slot !== null) return slot;
  if (node instanceof ShadowRoot) {
    // A shadow root's place in the flattened tree is its host's. An uncomposed event stops at the
    // root of the tree it was dispatched in; a root above that one still hands it on.
    if (!composed && node === treeRoot(target)) return null;
    return node.host;
  }
  return node.parentNode;
}

/** The root of the tree a node is in: the document, a shadow root, or a detached node. */
function treeRoot(n: Node): Node {
  let r: Node = n;
  while (r.parentNode !== null) r = r.parentNode;
  return r;
}

/**
 * Whether `anc` is `node`'s shadow-including inclusive ancestor. The walk crosses a shadow root to
 * its host and follows the node tree; a slot a node was given to is in the flattened tree, not
 * the shadow-including one, so it is not part of this relation (composedPath() hides a closed
 * tree's slot from a listener in the light tree for that reason).
 */
function shadowIncludingAncestor(anc: Node, node: Node): boolean {
  let n: Node | null = node;
  while (n !== null) {
    if (n === anc) return true;
    n = n instanceof ShadowRoot ? n.host : n.parentNode;
  }
  return false;
}

/**
 * The target a listener on `current` sees (the DOM's retargeting): a node inside a shadow tree is
 * reported as the host of the outermost tree the listener isn't inside, so a page never learns
 * what a widget's shadow tree holds. A node of the light tree, a slotted one included, is its own
 * target everywhere.
 */
function retarget(target: Node | null, current: Node | null): Node | null {
  let a = target;
  while (a !== null) {
    const root = treeRoot(a);
    if (!(root instanceof ShadowRoot)) return a;
    if (current !== null && shadowIncludingAncestor(root, current)) return a;
    a = root.host;
  }
  return a;
}

/**
 * Sends an event through the flattened tree from `target`: capture from the root inward, the
 * target's own listeners, then bubbling back out to the root when the event bubbles. A listener
 * above a shadow boundary sees the host as the target. Returns whether any listener cancelled.
 */
/** A node a slot may take: an element or a text node. */
function isSlottableNode(node: Node): boolean {
  return node instanceof Element || node instanceof Text;
}

/** Appends one item to an event's path, with the closed-tree flags composedPath() reads. */
function appendPathItem(event: Event, target: Node, adjusted: Node | null, related: Node | null, slotClosed: boolean): void {
  event.pathItems.push({
    target,
    adjusted,
    related,
    rootClosed: target instanceof ShadowRoot && target.mode === "closed",
    slotClosed,
  });
}

/** A window's listeners, reached from dispatch() without importing the window module. */
export interface WindowEventHost {
  invokeWindowListeners(type: string, event: Event, capture: boolean): void;
  windowObject(): Window;
}
let windowEventHost: WindowEventHost | null = null;
/** window.ts registers its singleton here when it loads (the DOM module type-imports it). */
export function setWindowEventHost(host: WindowEventHost | null): void {
  windowEventHost = host;
}

export function dispatch(event: Event, target: Node): boolean {
  event.dispatchFlag = true;
  event.windowCaptureRan = false;
  event.windowBubbleRan = false;
  event.pathItems = [];
  event.target = null;
  const related = event.relatedSource;
  const relatedAtTarget = related === null ? null : retarget(related, target);
  // The legacy `window.event` is the event while its listeners run, except for an event whose
  // target's root is a shadow tree: a listener inside one sees undefined, as browsers report. A
  // dispatch inside one restores the outer event when it ends.
  const outerEvent = currentEvent;
  if (!(treeRoot(target) instanceof ShadowRoot)) currentEvent = event;
  // An event whose related target retargets to the target itself has nowhere to go, unless it was
  // made with the target as its related target: nothing is dispatched at all.
  if (relatedAtTarget !== target || related === target) {
    appendPathItem(event, target, target, relatedAtTarget, false);
    let slottable: Node | null = isSlottableNode(target) && target.assignedSlot !== null ? target : null;
    let slotClosed = false;
    let current: Node = target;
    let parent: Node | null = eventParent(current, target, event.composed);
    while (parent !== null) {
      if (slottable !== null) {
        // This parent is the slot that took the node; a closed root marks the subtree.
        slottable = null;
        const root = treeRoot(parent);
        if (root instanceof ShadowRoot && root.mode === "closed") slotClosed = true;
      }
      if (isSlottableNode(parent) && parent.assignedSlot !== null) slottable = parent;
      const rel = related === null ? null : retarget(related, parent);
      if (shadowIncludingAncestor(treeRoot(current), parent)) {
        // The current target's tree reaches this parent, so the item keeps the target below it.
        appendPathItem(event, parent, null, rel, slotClosed);
      } else if (rel !== null && parent === rel) {
        // The walk ends at the related target.
        break;
      } else {
        current = parent;
        appendPathItem(event, parent, current, rel, slotClosed);
      }
      parent = eventParent(parent, target, event.composed);
      slotClosed = false;
    }
  }
  // The DOM decides the cleanup from the last item that carries a shadow-adjusted target, before
  // any listener runs: moving nodes during dispatch doesn't change the answer.
  let clear = false;
  let lastAdjusted: Node | null = null;
  for (let i = event.pathItems.length - 1; i >= 0; i--) {
    const item = event.pathItems[i];
    if (item.adjusted === null) continue;
    lastAdjusted = item.adjusted;
    if (treeRoot(item.adjusted) instanceof ShadowRoot) clear = true;
    if (item.related !== null && treeRoot(item.related) instanceof ShadowRoot) clear = true;
    break;
  }
  // The target each item shows: the last item at or below it that carries one.
  const shown: Node[] = [];
  let visible: Node = target;
  for (const item of event.pathItems) {
    if (item.adjusted !== null) visible = item.adjusted;
    shown.push(visible);
  }
  // The window is the outermost item when the event travels in the page's own document tree:
  // its capture listeners run before the document's, its bubble listeners after.
  const host = windowEventHost;
  const root = treeRoot(target);
  // The window hears an event whose target is in the page's tree, and a composed event that
  // leaves a connected shadow tree for it.
  const reachesWindow = host !== null && (root === document ||
    (event.composed && root instanceof ShadowRoot && root.host.isConnected));
  if (reachesWindow) {
    event.windowCaptureRan = true;
    host!.invokeWindowListeners(event.type, event, true);
  }
  // Capture: from the outermost item inward, the target's own listeners included.
  for (let i = event.pathItems.length - 1; i >= 0 && !event.propagationStopped; i--) {
    const item = event.pathItems[i];
    event.target = shown[i];
    event.relatedNow = item.related;
    event.eventPhase = item.adjusted !== null ? Event.AT_TARGET : Event.CAPTURING_PHASE;
    invokeListeners(item.target.listeners.get(event.type), item.target, event, true);
  }
  // Bubble: from the target outward; an item without a target of its own is skipped by an event
  // that doesn't bubble.
  for (let i = 0; i < event.pathItems.length && !event.propagationStopped; i++) {
    const item = event.pathItems[i];
    event.target = shown[i];
    event.relatedNow = item.related;
    if (item.adjusted !== null) event.eventPhase = Event.AT_TARGET;
    else if (event.bubbles) event.eventPhase = Event.BUBBLING_PHASE;
    else continue;
    invokeListeners(item.target.listeners.get(event.type), item.target, event, false);
  }
  // The bubble phase reaches the window only for an event that bubbles; a non-bubbling event
  // (focus, mouseenter, ...) still reaches its capture listeners there.
  if (reachesWindow && event.bubbles && !event.propagationStopped) {
    event.windowBubbleRan = true;
    host!.invokeWindowListeners(event.type, event, false);
  }
  event.eventPhase = Event.NONE;
  event.currentTarget = null;
  event.pathItems = [];
  event.dispatchFlag = false;
  // Dispatch ends with the propagation flags clear: the event can be dispatched again, and
  // cancelBubble reads false afterwards, as the DOM's dispatch step has it.
  event.propagationStopped = false;
  event.immediateStopped = false;
  currentEvent = outerEvent;
  if (clear) {
    event.clearTargets();
  } else {
    event.target = lastAdjusted !== null ? lastAdjusted : target;
    event.relatedNow = related === null ? null : retarget(related, null);
  }
  return !event.defaultPrevented;
}

/** scrollIntoView needs layout, so it runs after the next layout pass. */
export const pendingScrollIntoView = { el: null as Element | null, block: "start", inline: "nearest", behavior: "" };

/**
 * The offset queries live in layout/geometry.ts, which imports this module, so that module fills
 * these in when it loads. The answers here hold until it does: an offset parent by CSSOM View's
 * rule, and zero offsets, which is what a laid-out box has before any layout pass ran.
 */
export const geometry: {
  offsetParent: (el: Node) => Node | null;
  offsetLeft: (el: Node) => number;
  offsetTop: (el: Node) => number;
} = {
  offsetParent(el: Node): Node | null {
    let a = el.parentElement;
    while (a !== null) {
      if (a.sv[P.P_POSITION] !== P.POS_STATIC) return a;
      a = a.parentElement;
    }
    return null;
  },
  offsetLeft(el: Node): number {
    void el;
    return 0;
  },
  offsetTop(el: Node): number {
    void el;
    return 0;
  },
};

// ---------------------------------------------------------------------------
// Focus

export const focusState = { el: null as Element | null };
/**
 * Whether the last interaction came from the keyboard. Programmatic focus follows it, which is
 * how a browser decides :focus-visible for a script's focus() call.
 */
let lastInputIsKey = false;

/** Records the kind of interaction that just happened ("key" or "pointer"). */
export function noteInput(kind: "key" | "pointer"): void {
  lastInputIsKey = kind === "key";
}

/** Whether the element always shows a focus ring when focused: text fields do. */
function alwaysFocusVisible(el: Element): boolean {
  if (el.localName === "textarea") return true;
  if (!(el instanceof HTMLInputElement)) return false;
  const t = el.type;
  return t === "" || t === "text" || t === "search" || t === "url" || t === "tel" || t === "email" ||
    t === "password" || t === "number" || t === "date" || t === "datetime-local" || t === "month" ||
    t === "time" || t === "week";
}

/**
 * Focuses `el` (or clears focus). `visible` decides whether the focus counts as keyboard focus,
 * which :focus-visible matches; when it is omitted the element and the last interaction decide.
 */
/** A hook the accessibility layer sets: focus moved, so its tree's focused node changed. */
let focusChangedHook: (() => void) | null = null;

export function setFocusChangedHook(fn: (() => void) | null): void {
  focusChangedHook = fn;
}

/** A hook the composition layer sets: an element is about to lose focus, so it can commit the
 *  marked text it is showing before the blur reaches the page. */
let focusLostHook: ((el: Element) => void) | null = null;

export function setFocusLostHook(fn: ((el: Element) => void) | null): void {
  focusLostHook = fn;
}

/** A hook the accessibility layer sets: a control's value or text moved. */
let axChangeHook: (() => void) | null = null;

export function setAxChangeHook(fn: (() => void) | null): void {
  axChangeHook = fn;
}

/** Told when boxes moved without the tree changing (a scroll): the accessibility tree's rects
 *  are stale even though its nodes are not. */
let axGeometryHook: (() => void) | null = null;

export function setAxGeometryHook(fn: (() => void) | null): void {
  axGeometryHook = fn;
}

export function setFocus(el: Element | null, visible?: boolean): void {
  const prev = focusState.el;
  const ring = el !== null && (visible ?? (alwaysFocusVisible(el) || lastInputIsKey));
  if (prev === el) {
    if (el !== null) {
      const was = el.state;
      el.state = ring ? el.state | P.S_FOCUS_VISIBLE : el.state & ~P.S_FOCUS_VISIBLE;
      if (el.state !== was) restyleForState(el, P.S_FOCUS_VISIBLE);
      invalidatePaint();
    }
    return;
  }
  // While an element loses focus the document has no focused element: a blur and focusout
  // listener sees the body as the active element, as a browser's does. The new element takes
  // focus before its focus and focusin events fire.
  if (prev !== null) focusState.el = null;
  else focusState.el = el;
  // :focus-within moves on every ancestor of both elements, which the style pass works out.
  if ((stateUsage.mask & P.S_FOCUS_WITHIN) !== 0) invalidateStyle();
  if (prev !== null) {
    if (focusLostHook !== null) focusLostHook(prev);
    prev.state = prev.state & ~(P.S_FOCUS | P.S_FOCUS_VISIBLE);
    restyleForState(prev, P.S_FOCUS | P.S_FOCUS_VISIBLE);
    dispatch(trusted(new FocusEvent("blur", { relatedTarget: el })), prev);
    dispatch(trusted(new FocusEvent("focusout", { bubbles: true, composed: true, relatedTarget: el })), prev);
    if (prev instanceof HTMLInputElement) {
      prev.commit();
      resetDateEdit(prev);
    }
  }
  if (el !== null) {
    focusState.el = el;
    el.state = el.state | P.S_FOCUS | (ring ? P.S_FOCUS_VISIBLE : 0);
    restyleForState(el, P.S_FOCUS | P.S_FOCUS_VISIBLE);
    if (el instanceof HTMLInputElement) {
      // What commit() compares against, so a blur with no edit sends no change: a checkbox's
      // checkedness is not its value, and a move away from one must not look like an edit.
      el.committed = el.val;
      // A date field starts editing from the value it holds, in its first segment.
      if (dateKindOf(el.type) !== null) {
        resetDateEdit(el);
        dateSetActive(el, 0);
      }
    }
    dispatch(trusted(new FocusEvent("focus", { relatedTarget: prev })), el);
    dispatch(trusted(new FocusEvent("focusin", { bubbles: true, composed: true, relatedTarget: prev })), el);
  }
  if (focusChangedHook !== null) focusChangedHook();
  invalidatePaint();
}

// ---------------------------------------------------------------------------
// The top layer
//
// Modal dialogs and open popovers paint above the whole page, in the order they were shown, no
// matter where they sit in the tree. A modal dialog's backdrop is painted under it.

const topLayer: Element[] = [];

/** Puts the element on top, after everything already there, without drawing it twice. */
export function addToTopLayer(el: Element): void {
  const at = topLayer.indexOf(el);
  if (at >= 0) topLayer.splice(at, 1);
  topLayer.push(el);
  invalidatePaint();
}

/** Takes the element out of the top layer; it paints where it sits again. */
export function removeFromTopLayer(el: Element): void {
  const at = topLayer.indexOf(el);
  if (at >= 0) {
    topLayer.splice(at, 1);
    invalidatePaint();
  }
}

/** The top-layer elements, bottom-most first. */
export function topLayerElements(): readonly Element[] {
  return topLayer;
}

/** Empties the top layer: a runner's next page starts with nothing on top of it. */
export function clearTopLayer(): void {
  topLayer.length = 0;
}

/** Whether the element paints from the top layer rather than where it sits in the tree. */
export function isInTopLayer(el: Node): boolean {
  return el instanceof Element && el.pseudoKind === P.PE_NONE && topLayer.indexOf(el) >= 0;
}

// ---------------------------------------------------------------------------
// Popovers

/** The open popovers, oldest first: the order they were shown in, for light dismiss. */
const openPopovers: Element[] = [];
let nextPopoverTarget = 0;
/** How many are open, so removing a subtree can skip the walk when there are none. */
let openPopoverCount = 0;

/**
 * Hides an open popover, firing beforetoggle and then toggle. A listener can cancel the
 * beforetoggle, except when the element is leaving the document: it is gone either way.
 */
function hidePopoverNow(el: Element, honorCancel: boolean = true): void {
  if ((el.state & P.S_POPOVER_OPEN) === 0) return;
  const before = new ToggleEvent("beforetoggle", { cancelable: true, oldState: "open", newState: "closed" });
  if (!dispatch(trusted(before), el) && honorCancel) return;
  el.state = el.state & ~P.S_POPOVER_OPEN;
  const at = openPopovers.indexOf(el);
  if (at >= 0) openPopovers.splice(at, 1);
  openPopoverCount--;
  removeFromTopLayer(el);
  invalidateStyle();
  invalidateLayout();
  dispatch(trusted(new ToggleEvent("toggle", { oldState: "open", newState: "closed" })), el);
}

/** Hides the popovers in a subtree that is leaving the document, as removing one does. */
function hidePopoversIn(node: Node): void {
  if (node.isElementNode && (node.state & P.S_POPOVER_OPEN) !== 0) hidePopoverNow(node as Element, false);
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) hidePopoversIn(c);
}

/** Whether `node` is the element or inside it. */
function insideNode(el: Element, node: Node | null): boolean {
  return node !== null && el.contains(node);
}

/** Whether the node is a popover invoker for `el`, or inside one. */
function isInvokerFor(el: Element, node: Node | null): boolean {
  let n: Node | null = node;
  while (n !== null) {
    if (n instanceof Element && n.popoverTargetElement === el) return true;
    n = n.parentElement;
  }
  return false;
}

/**
 * Light dismiss: a pointer that lands outside an open auto popover closes it, as a click does in
 * a browser. A press on the popover itself or on its invoker keeps it, so the click that follows
 * toggles it, and one inside a nested popover only closes the popovers outside that one.
 */
export function lightDismissPopovers(target: Node | null): void {
  for (let i = openPopovers.length - 1; i >= 0; i--) {
    const el = openPopovers[i];
    if (el.popover !== "auto") continue;
    if (insideNode(el, target) || isInvokerFor(el, target)) continue;
    hidePopoverNow(el);
  }
}

/** Escape closes the newest open auto popover, one per press. Returns whether one closed. */
export function dismissPopover(): boolean {
  for (let i = openPopovers.length - 1; i >= 0; i--) {
    if (openPopovers[i].popover === "auto") {
      hidePopoverNow(openPopovers[i]);
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Date and time fields

/**
 * The state behind a date or time field's segmented view: one number per segment (null for a
 * segment the user hasn't filled in), the segment being edited, and the digits typed into it.
 */
interface DateEdit {
  vals: (number | null)[];
  active: number;
  buffer: string;
}

const dateEdits = new WeakMap<HTMLInputElement, DateEdit>();

/** The kind of date field an input is, or null for another kind of field. */
export function dateKind(el: HTMLInputElement): DateKind | null {
  return dateKindOf(el.type);
}

/** Whether a time field shows a seconds segment: its step is finer than a minute, or its value has one. */
export function dateWithSeconds(el: HTMLInputElement): boolean {
  const kind = dateKindOf(el.type);
  if (kind !== "time" && kind !== "datetime-local") return false;
  if (stepSize(kind, el.getAttribute("step")) < 60000) return true;
  return /:\d\d:\d\d/.test(el.value);
}

/** The segments a date field draws, in the order it draws them. */
export function dateSegments(el: HTMLInputElement): SegmentDef[] {
  const kind = dateKindOf(el.type) ?? "date";
  return segmentsFor(kind, dateWithSeconds(el));
}

function dateInitialValues(el: HTMLInputElement, spec: SegmentDef[]): (number | null)[] {
  const kind = dateKindOf(el.type);
  const p = kind === null ? null : parseDateText(kind, el.value);
  if (p === null) return spec.map(() => null);
  const vals: (number | null)[] = segmentValues(spec, p);
  return vals;
}

/** A field's edit state, made from its value the first time anything asks for it. */
function dateEditOf(el: HTMLInputElement): DateEdit {
  let e = dateEdits.get(el);
  if (e === undefined) {
    const spec = dateSegments(el);
    e = { vals: dateInitialValues(el, spec), active: 0, buffer: "" };
    dateEdits.set(el, e);
  }
  return e;
}

/** Throws away a field's edit state, so its display and segments come from its value again. */
export function resetDateEdit(el: HTMLInputElement): void {
  dateEdits.delete(el);
}

/** One segment as the field draws it: its separator, its text and whether that is a placeholder. */
export interface DateSegmentView {
  key: string;
  prefix: string;
  text: string;
  placeholder: boolean;
  active: boolean;
}

/** What a date field draws: the segments in order, with the one being edited marked. */
export interface DateFieldView {
  kind: DateKind;
  segments: DateSegmentView[];
}

/** The segments a date or time field draws, or null for a field of another kind. */
export function dateFieldView(el: HTMLInputElement): DateFieldView | null {
  const kind = dateKindOf(el.type);
  if (kind === null) return null;
  const spec = dateSegments(el);
  const focused = focusState.el === el;
  const edit = dateEdits.get(el);
  const vals = edit !== undefined ? edit.vals : dateInitialValues(el, spec);
  const active = focused && edit !== undefined ? edit.active : -1;
  const buffer = focused && edit !== undefined ? edit.buffer : "";
  const out: DateSegmentView[] = [];
  for (let i = 0; i < spec.length; i++) {
    const s = spec[i];
    const v = vals[i];
    const set = v !== null;
    // The digits typed into the segment being edited show before they make a whole value, as a
    // browser shows a year being typed.
    const typing = i === active && buffer !== "";
    out.push({
      key: s.key,
      prefix: s.prefix,
      text: typing ? buffer : set ? segmentValueText(s, v as number) : s.placeholder,
      placeholder: !set && !typing,
      active: i === active,
    });
  }
  return { kind, segments: out };
}

/** The display text a date field draws, as one string, for a script or an assistive technology. */
export function dateFieldText(el: HTMLInputElement): string {
  const view = dateFieldView(el);
  if (view === null) return "";
  let text = "";
  for (const s of view.segments) text += s.prefix + s.text;
  return text;
}

function dateStringFromSegments(el: HTMLInputElement, vals: (number | null)[]): string | null {
  const kind = dateKindOf(el.type);
  if (kind === null) return null;
  return textFromSegments(kind, dateSegments(el), vals);
}

/** Applies a new set of segment values, sending "input" when the field's value moves. */
function dateApply(el: HTMLInputElement, vals: (number | null)[], active: number, buffer: string): void {
  const edit = dateEditOf(el);
  edit.vals = vals;
  edit.active = active;
  edit.buffer = buffer;
  const text = dateStringFromSegments(el, vals);
  const next = text === null ? "" : text;
  if (next !== el.val) {
    el.val = next;
    noteControlChange(el);
    dispatch(trusted(new InputEvent("input", { bubbles: true })), el);
  } else {
    invalidatePaint();
  }
}

/** The segment a field's click at an x offset falls in, for a caller that has the segment boxes. */
export function dateSetActive(el: HTMLInputElement, index: number): void {
  const spec = dateSegments(el);
  const edit = dateEditOf(el);
  edit.active = Math.max(0, Math.min(index, spec.length - 1));
  edit.buffer = "";
  invalidatePaint();
}

/** Moves the edited segment left or right, at the ends of the field staying where it is. */
export function dateMoveActive(el: HTMLInputElement, delta: number): void {
  const spec = dateSegments(el);
  const edit = dateEditOf(el);
  edit.active = Math.max(0, Math.min(edit.active + delta, spec.length - 1));
  edit.buffer = "";
  invalidatePaint();
}

/**
 * Types text into the segment being edited: digits make its number, a month field takes letters
 * of a month's name, and a 12-hour field takes A or P. Returns whether anything changed.
 */
export function dateTypeText(el: HTMLInputElement, text: string): boolean {
  const spec = dateSegments(el);
  const edit = dateEditOf(el);
  const i = edit.active;
  const s = spec[i];
  if (s === undefined || text === "") return false;
  if (s.key === "ampm") {
    const ch = text.toLowerCase();
    if (ch !== "a" && ch !== "p") return false;
    const vals = edit.vals.slice();
    vals[i] = ch === "p" ? 1 : 0;
    dateApply(el, vals, i, "");
    return true;
  }
  if (s.monthName && /[a-z]/i.test(text)) {
    const buffer = (edit.buffer + text).toLowerCase();
    const m = monthFromName(buffer);
    if (m === 0) return false;
    const vals = edit.vals.slice();
    vals[i] = m;
    // A name long enough to name one month moves on, as typing its last letter does.
    const done = buffer.length >= 3;
    const next = done ? Math.min(i + 1, spec.length - 1) : i;
    dateApply(el, vals, next, done ? "" : buffer);
    return true;
  }
  if (!/^[0-9]$/.test(text)) return false;
  const buffer = edit.buffer + text;
  const n = Number(buffer);
  const max = segmentMax(spec, edit.vals, i);
  // A digit that would push the number past its segment is ignored, as a browser ignores one that
  // doesn't fit; a leading zero is taken as the number it stands for.
  if (n > max && buffer.length > 1) return false;
  // A year needs its four digits before it makes a value; until then the digits are just typed.
  if (s.key === "year" && buffer.length < 4) {
    edit.buffer = buffer;
    edit.active = i;
    invalidatePaint();
    return true;
  }
  const vals = edit.vals.slice();
  vals[i] = Math.min(n, max);
  const done = buffer.length >= s.digits || n * 10 > max;
  const next = done ? Math.min(i + 1, spec.length - 1) : i;
  dateApply(el, vals, next, done ? "" : buffer);
  return true;
}

/** Steps the edited segment up or down one, on through its range, and sends "input". */
export function dateStepActive(el: HTMLInputElement, delta: number): boolean {
  const spec = dateSegments(el);
  const edit = dateEditOf(el);
  if (spec.length === 0) return false;
  const vals = adjustSegment(spec, edit.vals, edit.active, delta);
  dateApply(el, vals, edit.active, "");
  return true;
}

/** Clears the edited segment and the value with it, as Backspace does. */
export function dateClearActive(el: HTMLInputElement): boolean {
  const edit = dateEditOf(el);
  const vals = edit.vals.slice();
  vals[edit.active] = null;
  dateApply(el, vals, edit.active, "");
  return true;
}

/**
 * A string parsed as HTML's valid floating-point number: optional "-", digits with an optional
 * fraction of digits, and an optional exponent. NaN for anything else, including "" and "1."
 * (the form a field's value may hold, not the looser form user input may show while editing).
 */
function parseFloatingPointNumber(text: string): number {
  const s = text.trim();
  let i = 0;
  if (i < s.length && s[i] === "-") i++;
  let digits = 0;
  while (i < s.length && s[i] >= "0" && s[i] <= "9") { i++; digits++; }
  if (i < s.length && s[i] === ".") {
    i++;
    let fraction = 0;
    while (i < s.length && s[i] >= "0" && s[i] <= "9") { i++; fraction++; }
    if (digits === 0 && fraction === 0) return NaN;
    if (fraction === 0) return NaN;
    digits += fraction;
  }
  if (digits === 0) return NaN;
  if (i < s.length && (s[i] === "e" || s[i] === "E")) {
    i++;
    if (i < s.length && (s[i] === "+" || s[i] === "-")) i++;
    let exponent = 0;
    while (i < s.length && s[i] >= "0" && s[i] <= "9") { i++; exponent++; }
    if (exponent === 0) return NaN;
  }
  if (i !== s.length) return NaN;
  const n = Number(s);
  return isFinite(n) ? n : NaN;
}

/** The value a number field keeps of `text`: the number as written, or nothing when it names none. */
function sanitizeNumberText(text: string): string {
  if (text === "") return "";
  return isNaN(parseFloatingPointNumber(text)) ? "" : text.trim();
}

/** Whether an email address passes the check a browser's email field makes. */
function isEmailAddress(text: string): boolean {
  const at = text.indexOf("@");
  if (at <= 0 || at !== text.lastIndexOf("@")) return false;
  const domain = text.slice(at + 1);
  if (domain.length === 0 || domain.indexOf(".") <= 0 || domain[domain.length - 1] === ".") return false;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c <= 0x20 || c === 0x7f) return false;
  }
  return true;
}

/** Whether text is an absolute URL, as a browser's url field wants. */
function isAbsoluteUrl(text: string): boolean {
  const colon = text.indexOf(":");
  if (colon <= 0) return false;
  const scheme = text.slice(0, colon);
  for (let i = 0; i < scheme.length; i++) {
    const c = scheme[i];
    const alpha = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
    if (i === 0 ? !alpha : !(alpha || (c >= "0" && c <= "9") || c === "+" || c === "-" || c === ".")) return false;
  }
  return text.length > colon + 1;
}

/** The type mismatch an email or url field's value has, and whether it is the multiple email
 *  form, into a validity state. */
function textFieldValidity(el: HTMLInputElement, state: ValidityState): void {
  const type = el.type.toLowerCase();
  const value = el.value;
  if (value === "") return;
  if (type === "email") {
    const addresses = el.multiple ? value.split(",") : [value];
    for (const a of addresses) {
      if (!isEmailAddress(a.trim())) { state.typeMismatch = true; return; }
    }
  } else if (type === "url") {
    if (!isAbsoluteUrl(value.trim())) state.typeMismatch = true;
  }
}

/** The range and step constraints a number or range field's value fails. */
function numberFieldValidity(el: HTMLInputElement, state: ValidityState): void {
  const type = el.type.toLowerCase();
  if (type !== "number" && type !== "range") return;
  const text = type === "range" ? String(el.valueAsNumber) : el.val;
  if (text === "") return;
  const v = type === "range" ? el.valueAsNumber : parseFloatingPointNumber(text);
  if (isNaN(v)) { state.badInput = true; return; }
  const min = numberAttribute(el, "min", type === "range" ? 0 : NaN);
  const max = numberAttribute(el, "max", type === "range" ? 100 : NaN);
  if (!isNaN(min) && v < min) state.rangeUnderflow = true;
  if (!isNaN(max) && v > max) state.rangeOverflow = true;
  const stepAttr = el.getAttribute("step");
  if (stepAttr !== null && stepAttr.trim().toLowerCase() === "any") return;
  const declared = numberAttribute(el, "step", 1);
  const step = declared > 0 ? declared : 1;
  const base = !isNaN(min) ? min : 0;
  const q = (v - base) / step;
  if (Math.abs(q - Math.round(q)) > 1e-9) state.stepMismatch = true;
}

/** The maxlength attribute as the IDL property reads it: -1 when unset or not a number. */
function maxLengthOf(el: Element): number {
  return lengthAttribute(el, "maxlength");
}
/** The minlength attribute as the IDL property reads it. */
function minLengthOf(el: Element): number {
  return lengthAttribute(el, "minlength");
}
/** A length attribute's non-negative integer, or -1 when it is absent or not one. */
function lengthAttribute(el: Element, name: string): number {
  const v = el.getAttribute(name);
  if (v === null || v.trim() === "") return -1;
  const n = Number(v.trim());
  return isFinite(n) && n === Math.floor(n) && n >= 0 ? n : -1;
}

/** Writes a length IDL attribute: a negative value is an IndexSizeError, and a value that isn't
 *  a number is 0, as the IDL long conversion makes it. */
function setLengthAttribute(el: Element, name: string, value: any): void {
  const n = Number(value);
  if (n < 0) {
    throw new Error(`IndexSizeError: Failed to set the '${name}' property on 'HTMLElement': The value provided (${value}) is negative.`);
  }
  const whole = isNaN(n) ? 0 : Math.floor(n);
  el.setAttribute(name, String(whole));
}

/** The range and step constraints a date or time field's value fails, into a validity state. */
function dateFieldValidity(el: HTMLInputElement, state: ValidityState): void {
  const kind = dateKindOf(el.type);
  if (kind === null) return;
  // Segments a user started but didn't finish make bad input, even while no value shows.
  const edit = dateEdits.get(el);
  if (edit !== undefined) {
    let entered = edit.buffer !== "";
    for (let i = 0; i < edit.vals.length; i++) if (edit.vals[i] !== null) entered = true;
    if (entered && textFromSegments(kind, dateSegments(el), edit.vals) === null) state.badInput = true;
  }
  if (el.val === "") return;
  const pos = valuePosition(kind, el.val);
  if (isNaN(pos)) {
    state.badInput = true;
    return;
  }
  const min = valuePosition(kind, el.min);
  const max = valuePosition(kind, el.max);
  if (!isNaN(min) && !isNaN(max) && max < min) {
    if (pos > max && pos < min) state.rangeOverflow = true;
  } else {
    if (!isNaN(min) && pos < min) state.rangeUnderflow = true;
    if (!isNaN(max) && pos > max) state.rangeOverflow = true;
  }
  const step = stepSize(kind, el.getAttribute("step"));
  if (step > 0) {
    // A week steps from the Monday of 1970's first week; the other kinds step from zero.
    const base = !isNaN(min) ? min : kind === "week" ? weekStartDays(1970, 1) * 86400000 : 0;
    const q = (pos - base) / step;
    if (Math.abs(q - Math.round(q)) > 1e-9) state.stepMismatch = true;
  }
}

// ---------------------------------------------------------------------------
// <input>

export class HTMLInputElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLInputElement"; }
  val = "";
  /** The selection's ends. A date or time field has no variable-length selection, so its IDL
   *  getters answer null and their setters throw; these hold the numbers the field edits with. */
  private selStart = 0;
  private selEnd = 0;
  get selectionStart(): any {
    return dateKind(this) === null ? this.selStart : null;
  }
  set selectionStart(v: any) {
    if (dateKind(this) !== null) {
      throw new Error("InvalidStateError: Failed to set the 'selectionStart' property on 'HTMLInputElement': The input element's type ('" + this.type + "') does not support selection.");
    }
    this.selStart = v;
  }
  get selectionEnd(): any {
    return dateKind(this) === null ? this.selEnd : null;
  }
  set selectionEnd(v: any) {
    if (dateKind(this) !== null) {
      throw new Error("InvalidStateError: Failed to set the 'selectionEnd' property on 'HTMLInputElement': The input element's type ('" + this.type + "') does not support selection.");
    }
    this.selEnd = v;
  }
  /** The fixed end of the selection while extending it with shift or a drag. */
  anchor = 0;
  /** The value at focus or the last change event, for deciding when "change" fires. */
  committed = "";
  /** A checkbox's state. The box itself isn't drawn yet, but the property is the value frameworks set. */
  private checkedFlag = false;
  /** A checkbox whose state a script put between checked and unchecked. */
  private indeterminateFlag = false;
  /** Whether the element is disabled; the attribute and the property say the same thing. */
  private disabledFlag = false;
  /** The message setCustomValidity() was given, which a failed check reports. */
  private customMessage = "";
  /** The files a file input holds. There is no file picker, so only a script puts files here. */
  private fileList: File[] = [];
  /** The value ranges a script made over this control's value. */
  readonly valueRanges: OpaqueRange[] = [];

  constructor(id: string, rules: readonly number[], states: number) {
    super();
    this.initEl("input", id, "", rules, states, true);
  }

  protected makeClone(): Element {
    const copy = new HTMLInputElement(this.id, [], 0);
    copy.value = this.val;
    copy.checked = this.checked;
    copy.disabled = this.disabled;
    return copy;
  }

  get checked(): boolean {
    return this.checkedFlag;
  }
  set checked(v: boolean) {
    if (this.checkedFlag === v) return;
    this.checkedFlag = v;
    noteControlChange(this);
  }
  get indeterminate(): boolean {
    return this.indeterminateFlag;
  }
  set indeterminate(v: boolean) {
    if (this.indeterminateFlag === v) return;
    this.indeterminateFlag = v;
    noteControlChange(this);
  }
  get value(): string {
    // A checkbox or radio with no value attribute submits "on", as a browser's does.
    const t = this.type.toLowerCase();
    if ((t === "checkbox" || t === "radio") && this.val === "" && this.getAttribute("value") === null) return "on";
    // A colour field always holds a colour: with no value it shows black, as Chrome does.
    if (t === "color" && this.val === "") return "#000000";
    return this.val;
  }
  set value(v: any) {
    // A date or time field holds a canonical value, or nothing when the text names none.
    const kind = dateKindOf(this.type);
    if (kind !== null) {
      const text = sanitizeDateText(kind, v);
      if (text !== this.val) moveValueRanges(this, 0, this.val.length, text.length);
      this.val = text;
      this.selStart = text.length;
      this.selEnd = text.length;
      this.anchor = text.length;
      this.caretEnd = text.length;
      resetDateEdit(this);
      noteControlChange(this);
      return;
    }
    // A colour field takes a simple colour and nothing else: text that names none leaves it black.
    if (this.type.toLowerCase() === "color") {
      this.val = simpleColor(v) ?? "#000000";
      noteControlChange(this);
      return;
    }
    // A number field holds a number in the floating-point form a browser keeps, and nothing else.
    if (this.type.toLowerCase() === "number") {
      const text = sanitizeNumberText(v);
      if (text !== this.val) moveValueRanges(this, 0, this.val.length, text.length);
      this.val = text;
      this.selStart = text.length;
      this.selEnd = text.length;
      this.anchor = text.length;
      noteControlChange(this);
      return;
    }
    // A whole-value write is a replace of the field's text to a live value range; writing the
    // same text changes nothing.
    if (v !== this.val) moveValueRanges(this, 0, this.val.length, v.length);
    this.val = v;
    this.selStart = v.length;
    this.selEnd = v.length;
    this.anchor = v.length;
    // A value decides whether a placeholder shows, whether the field is valid, and its range.
    noteControlChange(this);
  }
  /**
   * A range, number or date-family field's value as a number: milliseconds for date, week, time
   * and datetime-local, months since 1970 for month. NaN for another kind of field or no value.
   */
  get valueAsNumber(): number {
    const t = this.type.toLowerCase();
    if (t === "range") return rangeSpec(this).value;
    if (t === "number") return this.val === "" ? NaN : Number(this.val);
    const kind = dateKindOf(t);
    if (kind !== null) return dateValueAsNumber(kind, this.val);
    return NaN;
  }
  set valueAsNumber(value: any) {
    const v = Number(value);
    const t = this.type.toLowerCase();
    if (v === Infinity || v === -Infinity) {
      throw new TypeError("Failed to set the 'valueAsNumber' property on 'HTMLInputElement': The provided double value is non-finite.");
    }
    if (t === "range") {
      const spec = rangeSpec(this);
      // A value that isn't a number leaves the field at the middle of its range, which is the
      // value a range with no value attribute shows.
      const n = isNaN(v) ? (spec.min + spec.max) / 2 : v;
      this.value = String(snapRange(n, spec.min, spec.max, spec.step));
      return;
    }
    if (t === "number") {
      this.value = isNaN(v) ? "" : String(v);
      return;
    }
    const kind = dateKindOf(t);
    if (kind !== null) {
      this.value = isNaN(v) ? "" : dateTextFromNumber(kind, v);
      return;
    }
    throw new Error(`InvalidStateError: Failed to set the 'valueAsNumber' property on 'HTMLInputElement': ` +
      "This input element does not support Number values.");
  }

  /**
   * A date family field's value as a Date: midnight UTC for the day, week or month it names, and
   * the time of day on 1970-01-01 for a time field. A datetime-local field has no such view, since
   * its value has no time zone.
   */
  get valueAsDate(): Date | null {
    const kind = dateKindOf(this.type);
    if (kind === null || kind === "datetime-local") return null;
    const ms = dateValueOfParts(kind, this.val);
    return isNaN(ms) ? null : new Date(ms);
  }
  set valueAsDate(v: any) {
    const kind = dateKindOf(this.type);
    if (kind === null || kind === "datetime-local") {
      throw new Error(`InvalidStateError: Failed to set the 'valueAsDate' property on 'HTMLInputElement': ` +
        "This input element does not support Date values.");
    }
    if (v === null) {
      this.value = "";
      return;
    }
    if (!(v instanceof Date)) {
      throw new TypeError("Failed to set the 'valueAsDate' property on 'HTMLInputElement': The provided value is not a Date.");
    }
    const ms = v.getTime();
    if (isNaN(ms)) {
      this.value = "";
      return;
    }
    if (kind === "month") {
      this.value = dateTextFromNumber(kind, monthIndexFromMs(ms));
      return;
    }
    this.value = dateTextFromNumber(kind, ms);
  }

  /** The min attribute, reflected verbatim: the earliest value the field may hold. */
  get min(): string {
    return this.getAttribute("min") ?? "";
  }
  set min(v: any) {
    this.setAttribute("min", String(v));
  }
  /** The max attribute, reflected verbatim: the latest value the field may hold. */
  get max(): string {
    return this.getAttribute("max") ?? "";
  }
  set max(v: any) {
    this.setAttribute("max", String(v));
  }
  /** The step attribute, reflected verbatim: how far stepUp() and stepDown() move, in seconds. */
  get step(): string {
    return this.getAttribute("step") ?? "";
  }
  set step(v: any) {
    this.setAttribute("step", String(v));
  }
  /** The pattern attribute, reflected verbatim: the regular expression the value must match. */
  get pattern(): string {
    return this.getAttribute("pattern") ?? "";
  }
  set pattern(v: any) {
    this.setAttribute("pattern", String(v));
  }
  /** maxlength as the IDL property reads it: -1 when the attribute is unset or invalid. */
  get maxLength(): number {
    return maxLengthOf(this);
  }
  set maxLength(v: any) {
    setLengthAttribute(this, "maxlength", v);
  }
  /** minlength as the IDL property reads it: -1 when the attribute is unset or invalid. */
  get minLength(): number {
    return minLengthOf(this);
  }
  set minLength(v: any) {
    setLengthAttribute(this, "minlength", v);
  }

  /** Steps the value up or down by `n` steps, refusing a kind that has no steps or any. */
  private stepBy(n: number): void {
    const t = this.type.toLowerCase();
    const kind = dateKindOf(t);
    if (kind === null && t !== "number" && t !== "range") {
      throw new Error(`InvalidStateError: Failed to execute 'stepUp' on 'HTMLInputElement': ` +
        "This input element does not support stepping.");
    }
    if (stepIsAny(this.getAttribute("step"))) {
      throw new Error(`InvalidStateError: Failed to execute 'stepUp' on 'HTMLInputElement': ` +
        "This input element's step attribute is 'any'.");
    }
    if (kind !== null) {
      const next = stepValue(kind, this.val, n, this.getAttribute("step"), this.min, this.max);
      if (next === null || next === this.val) return;
      this.value = next;
      return;
    }
    const spec = rangeSpec(this);
    const min = numberAttribute(this, "min", t === "range" ? 0 : -Infinity);
    const max = numberAttribute(this, "max", t === "range" ? 100 : Infinity);
    const stepAttr = this.getAttribute("step");
    const declared = stepAttr === null ? 1 : Number(stepAttr);
    const step = isFinite(declared) && declared > 0 ? declared : 1;
    if (min > max) return;
    let current = this.val === "" ? (t === "range" ? spec.value : 0) : Number(this.val);
    if (isNaN(current)) current = t === "range" ? spec.value : 0;
    if (current < min || current > max) return;
    // A number or range with no min steps from zero; an endless bound is no bound at all.
    const base = isFinite(min) ? min : 0;
    const q = (current - base) / step;
    const k = n > 0 ? Math.floor(q + 1e-9) + n : Math.ceil(q - 1e-9) + n;
    let target = base + k * step;
    if (target > max) target = base + Math.floor((max - base) / step + 1e-9) * step;
    if (target < min) target = base + Math.ceil((min - base) / step - 1e-9) * step;
    if (target < min || target > max) return;
    this.value = String(Math.round(target * 1e6) / 1e6);
  }
  /** Moves the value `n` steps forward, as the Up arrow does in a browser's field. */
  stepUp(n: number = 1): void {
    this.stepBy(n);
  }
  /** Moves the value `n` steps back, as the Down arrow does in a browser's field. */
  stepDown(n: number = 1): void {
    this.stepBy(-n);
  }
  get placeholder(): string {
    const v = this.getAttribute("placeholder");
    return v === null ? "" : v;
  }
  set placeholder(v: string) {
    this.setAttribute("placeholder", v);
    invalidatePaint();
  }
  get type(): string {
    const v = this.getAttribute("type");
    return v === null ? "text" : v;
  }
  set type(v: string) {
    this.setAttribute("type", v);
    invalidatePaint();
  }
  get name(): string {
    const v = this.getAttribute("name");
    return v === null ? "" : v;
  }
  set name(v: string) {
    this.setAttribute("name", v);
  }
  /** The value attribute: the value the field started with, which a form reset goes back to. */
  get defaultValue(): string {
    const v = this.getAttribute("value");
    return v === null ? "" : v;
  }
  set defaultValue(v: string) {
    this.setAttribute("value", v);
  }
  /** The checked attribute: the checkedness a form reset goes back to. */
  get defaultChecked(): boolean {
    return attributeFlag(this, "checked");
  }
  set defaultChecked(v: boolean) {
    setAttributeFlag(this, "checked", v);
  }
  get disabled(): boolean {
    return this.disabledFlag;
  }
  set disabled(v: boolean) {
    this.disabledFlag = v;
    setAttributeFlag(this, "disabled", v);
  }
  get readOnly(): boolean {
    return attributeFlag(this, "readonly");
  }
  set readOnly(v: boolean) {
    setAttributeFlag(this, "readonly", v);
  }
  get required(): boolean {
    return attributeFlag(this, "required");
  }
  set required(v: boolean) {
    setAttributeFlag(this, "required", v);
  }
  get multiple(): boolean {
    return attributeFlag(this, "multiple");
  }
  set multiple(v: boolean) {
    setAttributeFlag(this, "multiple", v);
  }
  get accept(): string {
    const v = this.getAttribute("accept");
    return v === null ? "" : v;
  }
  set accept(v: string) {
    this.setAttribute("accept", v);
  }
  /** The files the field holds. Nothing opens a picker here, so this stays empty unless set. */
  get files(): readonly File[] {
    return this.fileList;
  }
  set files(list: readonly File[]) {
    this.fileList = list.slice();
  }
  get form(): HTMLFormElement | null {
    return formOwnerFor(this);
  }
  get labels(): HTMLLabelElement[] {
    return labelsFor(this);
  }
  get textLength(): number {
    return this.val.length;
  }

  /** The text as drawn: bullets for password fields. */
  get displayText(): string {
    // A date or time field draws its segments, with a placeholder for each part it hasn't filled.
    if (dateKindOf(this.type) !== null) return dateFieldText(this);
    // A colour field shows a swatch rather than the value it holds.
    if (this.type.toLowerCase() === "color") return "";
    // A button, submit or reset input with no value shows its type's word, as a browser's does.
    if (buttonInputType(this.type) && this.val === "" && this.getAttribute("value") === null) {
      const t = this.type.toLowerCase();
      return t === "submit" ? "Submit" : t === "reset" ? "Reset" : "";
    }
    if (this.type !== "password") return this.val;
    let s = "";
    for (let i = 0; i < this.val.length; i++) s += "•";
    return s;
  }

  select(): void {
    // A date field selects its first segment instead of its text, which it has no range for.
    if (dateKindOf(this.type) !== null) {
      dateSetActive(this, 0);
      return;
    }
    this.anchor = 0;
    this.selStart = 0;
    this.selEnd = this.val.length;
    invalidatePaint();
  }
  setSelectionRange(start: number, end: number, direction: string = "none"): void {
    if (dateKindOf(this.type) !== null) {
      throw new Error("InvalidStateError: Failed to execute 'setSelectionRange' on 'HTMLInputElement': The input element's type ('" + this.type + "') does not support selection.");
    }
    const n = this.val.length;
    this.selStart = Math.max(0, Math.min(start, n));
    this.selEnd = Math.max(this.selStart, Math.min(end, n));
    if (direction === "backward") {
      this.anchor = this.selEnd;
      const swap = this.selStart;
      this.selStart = this.selEnd;
      this.selEnd = swap;
    } else {
      this.anchor = this.selStart;
    }
    // The caret is drawn at the moving end, which a range set from script moves too.
    this.caretEnd = this.selEnd;
    invalidatePaint();
  }
  /** Which end the selection is anchored at, and so which way a shift-click extends it. */
  get selectionDirection(): any {
    if (dateKindOf(this.type) !== null) return null;
    if (this.selStart === this.selEnd) return "none";
    return this.anchor === this.selStart ? "forward" : "backward";
  }
  set selectionDirection(direction: any) {
    if (dateKindOf(this.type) !== null) {
      throw new Error("InvalidStateError: Failed to set the 'selectionDirection' property on 'HTMLInputElement': The input element's type ('" + this.type + "') does not support selection.");
    }
    if (direction === "backward" && this.selStart !== this.selEnd) {
      const swap = this.selStart;
      this.selStart = this.selEnd;
      this.selEnd = swap;
      this.anchor = this.selEnd;
    } else if (direction === "none") {
      this.selStart = this.selEnd;
      this.anchor = this.selEnd;
    } else {
      this.anchor = this.selStart;
    }
  }
  /** Replaces the text from `start` to `end`, then moves the selection as `mode` says. */
  setRangeText(replacement: string, start?: number, end?: number, mode: string = "preserve"): void {
    if (dateKindOf(this.type) !== null) {
      throw new Error("InvalidStateError: Failed to execute 'setRangeText' on 'HTMLInputElement': The input element's type ('" + this.type + "') does not support selection.");
    }
    const from = start === undefined ? this.selStart : start;
    const to = end === undefined ? this.selectionEnd : end;
    moveValueRanges(this, from, to - from, replacement.length);
    this.val = this.val.slice(0, from) + replacement + this.val.slice(to);
    const after = from + replacement.length;
    if (mode === "select") {
      this.selectionStart = from;
      this.selectionEnd = after;
    } else if (mode === "start") {
      this.selectionStart = from;
      this.selectionEnd = from;
    } else if (mode === "end") {
      this.selectionStart = after;
      this.selectionEnd = after;
    }
    this.anchor = this.selectionStart;
    // The caret is drawn at the moving end, which a range set from script moves too.
    this.caretEnd = this.selectionEnd;
    noteControlChange(this);
  }

  /** Moves the caret to `pos`; with `extend`, grows the selection from the anchor instead. */
  moveCaret(pos: number, extend: boolean): void {
    pos = Math.max(0, Math.min(pos, this.val.length));
    if (!extend) this.anchor = pos;
    this.selStart = Math.min(this.anchor, pos);
    this.selEnd = Math.max(this.anchor, pos);
    this.caretEnd = pos;
    markPaintDirty(this);
  }
  /** The moving end of the selection (where the caret is drawn). */
  caretEnd = 0;
  /** The marked text an input method is composing, as a range in the value, or -1 for none. */
  composeStart = -1;
  composeEnd = -1;

  replaceSelection(text: string): void {
    const s = this.selStart;
    const e = this.selEnd;
    moveValueRanges(this, s, e - s, text.length);
    this.val = this.val.slice(0, s) + text + this.val.slice(e);
    this.moveCaret(s + text.length, false);
    noteControlChange(this);
    if (axChangeHook !== null) axChangeHook();
  }

  setAttribute(name: string, value: string | number | boolean): void {
    if (name === "value") {
      // The attribute is the default value; the field's value starts out as it does on the web.
      super.setAttribute(name, value);
      this.value = typeof value === "string" ? value : String(value);
    } else if (name === "type") {
      const nextKind = dateKindOf(String(value));
      super.setAttribute(name, value);
      // A field whose type changes takes the new type's value sanitisation: a colour field keeps a
      // colour of what it held, and shows black when it held none; a date field keeps the value
      // only when it is one the new type accepts.
      if (nextKind !== null) {
        this.val = sanitizeDateText(nextKind, this.val);
        resetDateEdit(this);
        noteControlChange(this);
      } else if (String(value).trim().toLowerCase() === "color") {
        this.val = simpleColor(this.val) ?? "#000000";
        noteControlChange(this);
      } else if (String(value).trim().toLowerCase() === "number") {
        this.val = sanitizeNumberText(this.val);
        noteControlChange(this);
      }
    } else if (name === "checked") {
      super.setAttribute(name, value);
      this.checked = true;
    } else if (name === "disabled") {
      super.setAttribute(name, value);
      this.disabledFlag = true;
    } else {
      super.setAttribute(name, value);
    }
  }

  removeAttribute(name: string): void {
    super.removeAttribute(name);
    if (name === "disabled") this.disabledFlag = false;
  }

  /**
   * Whether the field takes part in validation: a disabled field, a read-only text field and a
   * hidden or button field are barred from it.
   */
  get willValidate(): boolean {
    if (controlDisabled(this)) return false;
    const type = this.type;
    if (type === "hidden" || type === "button" || type === "reset" || type === "submit" ||
      type === "image") return false;
    if (this.readOnly && type !== "checkbox" && type !== "radio" && type !== "file") return false;
    return true;
  }

  /**
   * The constraints the field fails: `required`, a date family field's min/max/step, and the
   * custom error a script set.
   */
  get validity(): ValidityState {
    const state = new ValidityState();
    state.customError = this.customMessage !== "";
    const type = this.type.toLowerCase();
    if (this.willValidate && this.required) {
      if (type === "checkbox") state.valueMissing = !this.checked;
      else if (type === "radio") {
        const group: HTMLInputElement[] = [];
        radioGroup(this, group);
        let any = false;
        for (const r of group) if (r.checked) any = true;
        state.valueMissing = !any;
      } else if (type !== "range") {
        state.valueMissing = this.val === "";
      }
    }
    dateFieldValidity(this, state);
    textFieldValidity(this, state);
    numberFieldValidity(this, state);
    return state;
  }
  /** The message a failed check reports, or "" when the field is valid. */
  get validationMessage(): string {
    const state = this.validity;
    if (state.customError) return this.customMessage;
    if (!this.willValidate) return "";
    if (state.valueMissing) {
      const type = this.type;
      if (type === "checkbox" || type === "radio") return "Please check this box if you want to proceed.";
      return "Please fill out this field.";
    }
    if (state.badInput) return "Please enter a valid value.";
    if (state.rangeUnderflow) return `Value must be greater than or equal to ${this.min}.`;
    if (state.rangeOverflow) return `Value must be less than or equal to ${this.max}.`;
    if (state.stepMismatch) return "Please enter a valid value.";
    return "";
  }
  /** Sets the field's own error message; "" clears it. Custom validity is the field's whole check. */
  setCustomValidity(message: string): void {
    this.customMessage = message;
    noteControlChange(this);
  }
  /** Checks the field, firing "invalid" at it when a constraint fails. */
  checkValidity(): boolean {
    const state = this.validity;
    if (state.valid) return true;
    dispatch(trusted(new Event("invalid", { cancelable: true })), this);
    return false;
  }
  reportValidity(): boolean {
    return this.checkValidity();
  }

  /** Fires "change" if the value differs from the last committed value. */
  commit(): void {
    if (this.val !== this.committed) {
      this.committed = this.val;
      dispatch(trusted(new Event("change", { bubbles: true })), this);
    }
  }
}

// ---------------------------------------------------------------------------
// <canvas>

export class HTMLCanvasElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLCanvasElement"; }
  /** The bitmap's size in device pixels; the CSS box defaults to it, as on the web. */
  private pixelWidth = 300;
  private pixelHeight = 150;
  private context2d: CanvasRenderingContext2D | null = null;
  private contextGL: WebGL2RenderingContext | null = null;
  /** The host refused the context once; the canvas keeps that mode and doesn't retry, as a
   *  browser doesn't create a context it has already failed to create. */
  private contextGLFailed = false;

  constructor(id: string, rules: readonly number[], states: number) {
    super();
    this.initEl("canvas", id, "", rules, states, true);
  }

  protected makeClone(): Element {
    const copy = new HTMLCanvasElement(this.id, [], 0);
    // The bitmap size is a property, not an attribute the copy should gain.
    copy.pixelWidth = this.pixelWidth;
    copy.pixelHeight = this.pixelHeight;
    return copy;
  }

  get width(): number {
    return this.pixelWidth;
  }
  set width(v: number) {
    this.pixelWidth = Math.max(0, Math.floor(v));
    if (this.pixelWidth > 16384) this.pixelWidth = 16384;
    super.setAttribute("width", String(this.pixelWidth));
    this.resized();
  }
  get height(): number {
    return this.pixelHeight;
  }
  set height(v: number) {
    this.pixelHeight = Math.max(0, Math.floor(v));
    if (this.pixelHeight > 16384) this.pixelHeight = 16384;
    super.setAttribute("height", String(this.pixelHeight));
    this.resized();
  }

  private resized(): void {
    if (this.context2d !== null) this.context2d.resize(this.pixelWidth, this.pixelHeight);
    if (this.contextGL !== null) this.contextGL.resize(this.pixelWidth, this.pixelHeight);
    this.lOwnChanged = true;
    invalidateLayout(this);
  }

  setAttribute(name: string, value: string | number | boolean): void {
    if (name === "width" || name === "height") {
      const n = parseInt(typeof value === "string" ? value : String(value), 10);
      const size = Number.isNaN(n) ? 300 : Math.min(16384, Math.max(0, n));
      if (name === "width") this.pixelWidth = size;
      else this.pixelHeight = size;
      super.setAttribute(name, value);
      this.resized();
      return;
    }
    super.setAttribute(name, value);
  }

  getContext(kind: "2d", attributes?: null): CanvasRenderingContext2D | null;
  getContext(kind: "webgl2", attributes?: WebGLContextAttributes | null): WebGL2RenderingContext | null;
  getContext(kind: string, attributes?: WebGLContextAttributes | null): CanvasRenderingContext2D | WebGL2RenderingContext | null;
  getContext(kind: string, attributes?: WebGLContextAttributes | null): CanvasRenderingContext2D | WebGL2RenderingContext | null {
    if (kind === "2d") {
      if (this.contextGL !== null || this.contextGLFailed) return null;
      if (this.context2d === null) {
        this.context2d = createContext(this.pixelWidth, this.pixelHeight);
        // A draw on it damages the canvas box, not the page (style.ts's damage machinery).
        this.context2d.canvasEl = this;
      }
      return this.context2d;
    }
    if (kind === "webgl2") {
      // A second request for a different kind of context is null, as on the web.
      if (this.context2d !== null) return null;
      if (this.contextGL === null && !this.contextGLFailed) {
        this.contextGL = createWebGL2Context(this, this.pixelWidth, this.pixelHeight,
                                             attributes === undefined ? null : attributes);
        if (this.contextGL === null) this.contextGLFailed = true;
      }
      return this.contextGL;
    }
    return null;
  }

  /** The host bitmap paint draws, or -1 before the page asked for a context. */
  hostBitmapId(): number {
    if (this.context2d !== null) return this.context2d.hostId;
    if (this.contextGL !== null) return this.contextGL.hostId;
    return -1;
  }
}

/** An element's border box in viewport coordinates, as getBoundingClientRect() returns it. */
/** A point in a coordinate space, as GeometryUtils conversions return one. */
/** The pixel sources WebGL's texImage2D and texSubImage2D take: the three the runtime can hand
 *  the host. A browser also lists ImageBitmap, OffscreenCanvas and VideoFrame; the runtime has no
 *  such objects, so a program that names one of those still fails where it builds it. */
export type TexImageSource = ImageData | HTMLImageElement | HTMLCanvasElement;

export class DOMPoint {
  get [Symbol.toStringTag](): string { return "DOMPoint"; }
  x: number;
  y: number;
  z: number;
  w: number;
  constructor(x: number = 0, y: number = 0, z: number = 0, w: number = 1) {
    this.x = x; this.y = y; this.z = z; this.w = w;
  }
  static fromPoint(other: any): DOMPoint {
    const o = other === null || other === undefined ? {} : other;
    return new DOMPoint(o.x === undefined ? 0 : o.x, o.y === undefined ? 0 : o.y,
      o.z === undefined ? 0 : o.z, o.w === undefined ? 1 : o.w);
  }
  toJSON(): any { return { x: this.x, y: this.y, z: this.z, w: this.w }; }
}

/** A rectangle as a read-only view: the same fields, without the setters. */
export class DOMRectReadOnly {
  get [Symbol.toStringTag](): string { return "DOMRectReadOnly"; }
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  constructor(x: number = 0, y: number = 0, w: number = 0, h: number = 0) {
    this.x = x; this.y = y; this.width = w; this.height = h;
  }
  get top(): number { return this.y; }
  get left(): number { return this.x; }
  get right(): number { return this.x + this.width; }
  get bottom(): number { return this.y + this.height; }
  static fromRect(o: any = {}): DOMRectReadOnly {
    return new DOMRectReadOnly(o.x === undefined ? 0 : o.x, o.y === undefined ? 0 : o.y,
      o.width === undefined ? 0 : o.width, o.height === undefined ? 0 : o.height);
  }
  toJSON(): any { return { x: this.x, y: this.y, width: this.width, height: this.height }; }
}

/** Four points bounding a box, as GeometryUtils hands a box back. */
export class DOMQuad {
  get [Symbol.toStringTag](): string { return "DOMQuad"; }
  p1: DOMPoint; p2: DOMPoint; p3: DOMPoint; p4: DOMPoint;
  constructor(p1: DOMPoint = new DOMPoint(), p2: DOMPoint = new DOMPoint(),
    p3: DOMPoint = new DOMPoint(), p4: DOMPoint = new DOMPoint()) {
    this.p1 = p1; this.p2 = p2; this.p3 = p3; this.p4 = p4;
  }
  static fromRect(rect: any): DOMQuad {
    const x = rect.x === undefined ? (rect.left === undefined ? 0 : rect.left) : rect.x;
    const y = rect.y === undefined ? (rect.top === undefined ? 0 : rect.top) : rect.y;
    const w = rect.width === undefined ? 0 : rect.width;
    const h = rect.height === undefined ? 0 : rect.height;
    return new DOMQuad(new DOMPoint(x, y), new DOMPoint(x + w, y),
      new DOMPoint(x, y + h), new DOMPoint(x + w, y + h));
  }
  getBoundingClientRect(): DOMRect {
    let l = Math.min(this.p1.x, this.p2.x, this.p3.x, this.p4.x);
    let t = Math.min(this.p1.y, this.p2.y, this.p3.y, this.p4.y);
    let r = Math.max(this.p1.x, this.p2.x, this.p3.x, this.p4.x);
    let b = Math.max(this.p1.y, this.p2.y, this.p3.y, this.p4.y);
    return new DOMRect(l, t, r - l, b - t);
  }
  /** The DOMRect bounding the four points, the name Chrome's GeometryUtils gives it. */
  getBounds(): DOMRect {
    return this.getBoundingClientRect();
  }
}

export class DOMRect {
  get [Symbol.toStringTag](): string { return "DOMRect"; }
  x: number;
  y: number;
  width: number;
  height: number;

  constructor(x: number, y: number, width: number, height: number) {
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }
  get left(): number {
    return this.x;
  }
  get top(): number {
    return this.y;
  }
  get right(): number {
    return this.x + this.width;
  }
  get bottom(): number {
    return this.y + this.height;
  }
}

/** A `<template>`: its children are parsed into a fragment that isn't part of the tree. */
export class HTMLTemplateElement extends HTMLElement {
  get [Symbol.toStringTag](): string { return "HTMLTemplateElement"; }
  readonly content: DocumentFragment = new DocumentFragment();

  constructor(id: string, rules: readonly number[], states: number) {
    super();
    this.initEl("template", id, "", rules, states, false);
  }

  protected makeClone(): Element {
    return new HTMLTemplateElement(this.id, [], 0);
  }

  // The declarative shadow root attributes, as HTMLTemplateElement reflects them.
  get shadowRootMode(): string {
    const v = this.getAttribute("shadowrootmode");
    return v === null ? "" : v;
  }
  set shadowRootMode(value: string) {
    this.setAttribute("shadowrootmode", value);
  }
  get shadowRootDelegatesFocus(): boolean {
    return this.hasAttribute("shadowrootdelegatesfocus");
  }
  set shadowRootDelegatesFocus(value: boolean) {
    if (value) this.setAttribute("shadowrootdelegatesfocus", "");
    else this.removeAttribute("shadowrootdelegatesfocus");
  }
  get shadowRootClonable(): boolean {
    return this.hasAttribute("shadowrootclonable");
  }
  set shadowRootClonable(value: boolean) {
    if (value) this.setAttribute("shadowrootclonable", "");
    else this.removeAttribute("shadowrootclonable");
  }
  get shadowRootSerializable(): boolean {
    return this.hasAttribute("shadowrootserializable");
  }
  set shadowRootSerializable(value: boolean) {
    if (value) this.setAttribute("shadowrootserializable", "");
    else this.removeAttribute("shadowrootserializable");
  }
  get shadowRootSlotAssignment(): string {
    const v = this.getAttribute("shadowrootslotassignment");
    return v === null ? "named" : v;
  }
  set shadowRootSlotAssignment(value: string) {
    this.setAttribute("shadowrootslotassignment", value);
  }

  /** The template's markup lives in its content, so a deep copy copies that. */
  cloneNode(deep: boolean = false): Node {
    const copy = this.shallowClone() as HTMLTemplateElement;
    if (deep) {
      if (this.ownText !== "") copy.content.appendChild(new Text(this.ownText));
      for (const c of this.content.kids) if (c.pseudoKind === P.PE_NONE) copy.content.appendChild(c.cloneNode(true));
    }
    return copy;
  }

  get innerHTML(): string {
    if (this.ownText !== "" && this.content.kids.length === 0) return escapeText(this.ownText);
    return markupOfChildren(this.content);
  }
  set innerHTML(html: string) {
    this.content.replaceChildren(...parseFragment(html));
  }
  get outerHTML(): string {
    return "<template>" + markupOfChildren(this.content) + "</template>";
  }
}

/**
 * Parses the selector a DOM query method was given, as browsers do: a selector that doesn't
 * parse throws a SyntaxError, and a selector list may hold any number of selectors. The runtime
 * has no DOMException class, so the error's message carries the name, as the other DOM errors
 * here do.
 */
function parseSelectorArg(selector: string, method: string, owner: string): Selector[] {
  const where = `Failed to execute '${method}' on '${owner}': `;
  if (selector.trim() === "") {
    throw new Error("SyntaxError: " + where + "The provided selector is empty.");
  }
  const out: Selector[] = [];
  for (const part of splitTopLevel(selector, ",")) {
    const text = part.trim();
    // One selector of the list. A :is()/:where() expands into several selectors that mean the
    // same thing together, and a selector naming nothing parses to none of them.
    const sels = text === "" ? null : parseSelector(text, true);
    if (sels === null) {
      throw new Error("SyntaxError: " + where + "'" + selector + "' is not a valid selector.");
    }
    for (const s of sels) out.push(s);
  }
  return out;
}

/** Does the element match any selector of a list, with `scope` for its :scope? */
function matchesAny(el: Element, sels: Selector[], scope: Element | null): boolean {
  if (el.pseudoKind !== P.PE_NONE) return false;
  for (const s of sels) if (selectorMatches(el, s, scope)) return true;
  return false;
}

/** The first match under a node, in tree order. */
function firstMatch(el: Node, sels: Selector[], scope: Element | null): Element | null {
  for (const c of el.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    const e = c as Element;
    if (matchesAny(e, sels, scope)) return e;
    const found = firstMatch(e, sels, scope);
    if (found !== null) return found;
  }
  return null;
}

/** Every match under a node, in tree order. */
function collectMatches(el: Node, sels: Selector[], scope: Element | null, out: Element[]): void {
  for (const c of el.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    const e = c as Element;
    if (matchesAny(e, sels, scope)) out.push(e);
    collectMatches(e, sels, scope, out);
  }
}

// ---------------------------------------------------------------------------
// Inline geometry

/** Is the element generated at all? A display: none box has no rects and no box, and neither
 *  has one that isn't in the document, since nothing laid it out. A box inside a display: none
 *  subtree isn't generated either: the subtree drops out whole, whatever the box's own display. */
function isUnrendered(el: Element): boolean {
  if (el.nodeType !== 1 || !el.isConnected) return true;
  for (let p: Element | null = el; p !== null; p = p.parentElement) {
    if (p.sv[P.P_DISPLAY] === P.D_NONE) return true;
  }
  return false;
}

/**
 * Is the element's own box an inline box? Its width and height come from the line it sits in
 * rather than from a box of its own, so its rects are its fragments. A replaced element
 * (an image or a canvas) is inline-level but has a box of its own.
 */
function isInlineBox(el: Element): boolean {
  if (isUnrendered(el)) return false;
  if (display(el) !== P.D_INLINE) return false;
  return el.localName !== "img" && el.localName !== "canvas";
}

/** The border box's origin in viewport coordinates, after scrolling. The same walk as
 *  absolutePosition() in layout/geometry.ts, which this module can't import for the cycle. */
function viewportOrigin(el: Node): number[] {
  let x = 0;
  let y = 0;
  let e: Node | null = el;
  // A box inside a viewport-anchored fixed box doesn't move when an ancestor of that box
  // scrolls, so the scrolls above it are not subtracted.
  let anchored = false;
  while (e !== null) {
    x += e.x + stickyShiftHook(e, true);
    y += e.y + stickyShiftHook(e, false);
    if (e.fixedViewport) anchored = true;
    const p: Node | null = e.parentElement;
    if (p !== null && !anchored) {
      y -= p.scrollY;
      x -= p.scrollX;
    }
    e = p;
  }
  return [x, y];
}

/**
 * The block container that laid this element out as inline content: the nearest ancestor with
 * fragments. The fragments record, relative to its border box, where every run of its line
 * went, which is where an inline box's rects come from.
 */
function fragmentHolder(el: Element): Node | null {
  let a = el.parentElement;
  while (a !== null) {
    if (a.fragKind.length > 0) return a;
    a = a.parentElement;
  }
  return null;
}

/** Is `node` the element or one of its descendants? */
function inSubtree(node: Node, el: Element): boolean {
  let e: Node | null = node;
  while (e !== null) {
    if (e === el) return true;
    e = e.parentElement;
  }
  return false;
}

/**
 * The inline box a fragment belongs to: its own element when that is an inline box, and for an
 * atomic box in the line (an inline-block, an image) the inline box around it, since the line
 * runs through the atomic box without splitting the inline box that holds it.
 */
function inlineStyleOf(node: Node, holder: Node): Node {
  let e: Node | null = node;
  while (e !== null) {
    if (isInlineBox(e as Element)) return e;
    if (e === holder) break;
    e = e.parentElement;
  }
  return holder;
}

/**
 * An inline box's rects: one per run of content, per line, since that is how browsers fragment
 * an inline box (a line break splits it, and so does a nested inline box). A nested atomic box
 * doesn't split it, though the line runs through it. Each rect is the run's border box: the font
 * box of the inline box, plus its vertical padding and border, with its margins left out.
 */
function inlineClientRects(el: Element): DOMRect[] {
  const holder = fragmentHolder(el);
  if (holder === null) return [];
  const out: DOMRect[] = [];
  const origin = viewportOrigin(holder);
  // Percentages on an inline box resolve against its containing block's width.
  const base = holder.contentW;
  let i = 0;
  while (i < holder.fragKind.length) {
    if (!inSubtree(holder.fragOwner[i], el)) {
      i++;
      continue;
    }
    const style = inlineStyleOf(holder.fragOwner[i], holder);
    const line = holder.fragLine[i];
    // The run goes on while the content stays in the same inline box on the same line and
    // touches what came before it.
    let j = i;
    while (j + 1 < holder.fragKind.length) {
      const k = j + 1;
      if (inlineStyleOf(holder.fragOwner[k], holder) !== style) break;
      if (holder.fragLine[k] !== line) break;
      if (Math.abs(holder.fragX[k] - (holder.fragX[j] + holder.fragW[j])) > 0.01) break;
      j = k;
    }
    out.push(fragmentRect(holder, i, j, style as Element, origin, base));
    i = j + 1;
  }
  return out;
}

/**
 * A rect placed in a box's own axes, put back on the page. Fragments and line boxes are recorded
 * from the border box in the frame's axes, and a box that lays its content out down the page turns
 * them a quarter about its content box's corner, which is where the text really starts.
 */
function frameRect(holder: Node, origin: number[], left: number, top: number, w: number, h: number): DOMRect {
  if (holder.vtext === 0) return new DOMRect(origin[0] + left, origin[1] + top, w, h);
  const m = usedWritingMode(holder);
  const vlr = m === P.WM_VERTICAL_LR || m === P.WM_SIDEWAYS_LR;
  // The content box's corner in the frame's own coordinates, measured from the border box.
  const inlineStart = holder.contentY;
  const blockStart = vlr ? holder.contentX : holder.w - holder.contentX - holder.contentW;
  const u = left - inlineStart;
  const v = top - blockStart;
  const cx = origin[0] + holder.contentX;
  const cy = origin[1] + holder.contentY;
  // A frame's block axis runs towards the page's right in the -lr modes and towards its left in
  // the -rl ones, so only the -rl modes measure a block offset back from the content's far edge.
  return new DOMRect(vlr ? cx + v : cx + holder.contentW - v - h, cy + u, h, w);
}

/** The rect of one run of fragments, in viewport coordinates. */
function fragmentRect(holder: Node, i: number, j: number, style: Element, origin: number[], base: number): DOMRect {
  if (!isInlineBox(style)) {
    // The holder itself, which can only happen for content outside every inline box.
    const p = viewportOrigin(style);
    return new DOMRect(p[0], p[1], style.w, style.h);
  }
  // A line that takes up no height (an inline box around nothing) gives a rect with no height,
  // at the top of the line box, rather than the font box.
  if (holder.fragLine[i] === EMPTY_LINE) {
    return frameRect(holder, origin, holder.fragX[i], holder.fragTop[i], 0, 0);
  }
  let left = holder.fragX[i];
  let right = holder.fragX[j] + holder.fragW[j];
  // An edge fragment is its margin, border and padding; a rect is the border box, so the margin
  // at either end of the run stays outside it. An edge at a line break has none of them (it is
  // zero wide), and leaves the run where it is.
  if (holder.fragKind[i] === FRAG_EDGE && Math.abs(holder.fragW[i]) > 0.001) {
    left += zeroIfNaN(len(style, P.P_MARGIN_LEFT, base));
  }
  if (holder.fragKind[j] === FRAG_EDGE && Math.abs(holder.fragW[j]) > 0.001) {
    right -= zeroIfNaN(len(style, P.P_MARGIN_RIGHT, base));
  }
  // A fragment's top is the top of its line-height box, so the font box starts below it by the
  // upper leading. The border box starts above that by the padding and border, and is as tall
  // as the font box and those make it.
  const above = zeroIfNaN(len(style, P.P_PADDING_TOP, base)) + borderTop(style);
  const below = zeroIfNaN(len(style, P.P_PADDING_BOTTOM, base)) + borderBottom(style);
  return frameRect(holder, origin, left, holder.fragTop[i] + fontBoxLeading(style) - above,
    right - left, fontBoxHeight(style) + above + below);
}

// ---------------------------------------------------------------------------
// Selection

/** One run of text in the document order a selection reads: a text node or an element's own text. */
interface TextRun {
  node: Node;
  /** The run's first character, counting every character before it in the document. */
  at: number;
  text: string;
}

/** Every text run below `root`, with its character offset in the stream a Range counts along. */
function textRuns(root: Node): TextRun[] {
  const out: TextRun[] = [];
  let n = 0;
  const walk = (node: Node): void => {
    if (node.isTextNode) {
      out.push({ node, at: n, text: node.ownText });
      n += node.ownText.length;
      return;
    }
    if (!node.isElementNode) return;
    const el = node as Element;
    // A generated box's text is style's, not the DOM's: ::before and ::after content and a drop
    // cap's floated letter are not part of the document's text.
    if (el.pseudoKind !== P.PE_NONE) return;
    if (el.ownText !== "") {
      out.push({ node: el, at: n, text: el.ownText });
      n += el.ownText.length;
    }
    for (const c of el.kids) walk(c);
  };
  walk(root);
  return out;
}

/**
 * The run a node's text is in, by node: the stream is walked once when it is built, and the
 * selection maps every run it paints through it, so this lookup cannot cost a walk of the page.
 */
const runIndex = new WeakMap<TextRun[], Map<Node, TextRun>>();
function runsByNode(runs: TextRun[]): Map<Node, TextRun> {
  let map = runIndex.get(runs);
  if (map === undefined) {
    map = new Map<Node, TextRun>();
    for (const r of runs) map.set(r.node, r);
    runIndex.set(runs, map);
  }
  return map;
}

/** A point's character offset in the stream `runs` counts, resolving a child index in an element. */
function pointAt(runs: TextRun[], node: Node, offset: number): number {
  const own = runsByNode(runs).get(node);
  if (own !== undefined) return own.at + Math.max(0, Math.min(offset, own.text.length));
  // An element container: the point is before child number `offset`, which is the end of the
  // own text plus the text of the children before it. Any other node outside the runs (a text
  // node a selection outlived) has no place in the stream.
  if (!node.isElementNode) return 0;
  const el = node as Element;
  const before: Node[] = el.kids.slice(0, Math.max(0, Math.min(offset, el.kids.length)));
  let at = 0;
  for (const r of runs) if (r.node === el) at = r.at + r.text.length;
  for (const r of runs) {
    if (r.node === el) continue;
    let owner: Node | null = r.node;
    while (owner !== null && owner !== el) owner = owner.parentNode;
    if (owner !== el) continue;
    let inside = false;
    for (const b of before) if (insideNodeDeep(b, r.node)) inside = true;
    if (inside) at = r.at + r.text.length;
    else if (r.at >= at) break;
  }
  return at;
  return 0;
}

/**
 * The base every range has in common. A browser's AbstractRange has no constructor a page can
 * call; the ranges that exist (Range, StaticRange, OpaqueRange) extend it.
 */
export class AbstractRange {
  get [Symbol.toStringTag](): string { return "AbstractRange"; }
  constructor(token?: string) {
    if (token !== "abstract-range") throw new TypeError("Failed to construct 'AbstractRange': Illegal constructor");
  }
  /** The boxes the range covers; a range type that measures nothing answers with none. */
  getClientRects(): DOMRect[] {
    return [];
  }
  /** The box around the range's text, as getClientRects() makes it up. */
  getBoundingClientRect(): DOMRect {
    return new DOMRect(0, 0, 0, 0);
  }
  /** The tree the range lives in: the document, a shadow root, or the control's root. */
  get rangeRoot(): Node {
    return document;
  }
}

/** A boundary point moved past an edit, as replace data moves a live range's. */
function moveRangeBoundary(at: number, offset: number, count: number, delta: number): number {
  // A point inside the stretch that was replaced goes to the start of the replacement; one past
  // it moves by the change in length; one before it stays put (an insertion at the point itself
  // leaves a collapsed range alone, as the spec's strictly-greater tests do).
  if (at > offset && at <= offset + count) return offset;
  if (at > offset + count) return at + delta;
  return at;
}

/** The input types the Selection API covers: the ones that show editable text. */
const VALUE_RANGE_INPUT_TYPES = new Set(["text", "search", "url", "tel", "password"]);

/** The boxes a value range covers: one per line of text, and the box around them all. */
export interface ValueRangeGeometry {
  rects: DOMRect[];
  bound: DOMRect;
}

// Where a field's text is drawn is the painter's knowledge (text measurement and layout), so the
// painter sets this hook rather than this module importing it.
let valueRangeGeometryHook: ((el: HTMLElement, start: number, end: number) => ValueRangeGeometry) | null = null;

/** Lets the painter answer a value range's geometry. */
export function setValueRangeGeometryHook(fn: (el: HTMLElement, start: number, end: number) => ValueRangeGeometry): void {
  valueRangeGeometryHook = fn;
}

/** Whether a control's value is text an OpaqueRange can cover. */
function valueRangeSupported(el: HTMLElement): boolean {
  if (el instanceof HTMLTextAreaElement) return true;
  if (el instanceof HTMLInputElement) return VALUE_RANGE_INPUT_TYPES.has(el.type.toLowerCase());
  return false;
}

/** Moves every value range a control holds past an edit of its text. */
function moveValueRanges(control: HTMLInputElement | HTMLTextAreaElement, offset: number, count: number, dataLength: number): void {
  for (const r of control.valueRanges) r.replaceData(offset, count, dataLength);
}

/**
 * A live range over a form control's value. Its boundaries are offsets into the text the control
 * holds, not nodes of the tree, so `startContainer` and `endContainer` stay undefined. The range
 * follows the value: an edit moves its boundaries as replace data moves a DOM range's, and it
 * collapses for good when it is disconnected, when the control leaves the document, or when the
 * control stops holding value text (an input changed to a color well, say).
 */
export class OpaqueRange extends AbstractRange {
  get [Symbol.toStringTag](): string { return "OpaqueRange"; }
  /** The control whose value this range covers, until it is detached. */
  private control: HTMLElement | null;
  private start = 0;
  private end = 0;
  /** Whether the control has been in a document since the range was made. */
  private wasConnected = false;
  /** The document the control belonged to when the range was made. */
  private owner: Document | null = null;
  /** An input's type when the range was made: changing it takes the range's text away. */
  private inputType: string | null = null;
  private detached = false;

  /** Made by createValueRange(); a page can't construct one. */
  constructor(control?: HTMLElement, token?: string) {
    super("abstract-range");
    if (token !== "value-range" || control === undefined) {
      throw new TypeError("Failed to construct 'OpaqueRange': Illegal constructor");
    }
    this.control = control;
    this.owner = control.ownerDocument;
    this.wasConnected = control.isConnected;
    if (control instanceof HTMLInputElement) this.inputType = control.type.toLowerCase();
  }

  /** The offsets in the control's value; they move with it, so they are read live. */
  get startOffset(): number {
    this.sync();
    return this.start;
  }
  get endOffset(): number {
    this.sync();
    return this.end;
  }
  get collapsed(): boolean {
    this.sync();
    return this.start === this.end;
  }

  /** The tree the control sits in, which is where this range's text is drawn. */
  get rangeRoot(): Node {
    return this.control === null ? document : this.control.getRootNode();
  }

  /** The boundaries createValueRange() gave, after a backwards range collapses to its start. */
  setBoundaries(start: number, end: number): void {
    this.start = start;
    this.end = end < start ? start : end;
  }

  /** Moves the boundaries past an edit of the value, as replace data moves a live range's. */
  replaceData(offset: number, count: number, dataLength: number): void {
    if (this.detached) return;
    const delta = dataLength - count;
    this.start = moveRangeBoundary(this.start, offset, count, delta);
    this.end = moveRangeBoundary(this.end, offset, count, delta);
  }

  /** Lets the range go: it collapses and stops following the control's value. */
  disconnect(): void {
    this.start = 0;
    this.end = 0;
    this.detached = true;
  }

  /** The boxes the covered text draws in; a collapsed range has none, a detached one none at all. */
  getClientRects(): DOMRect[] {
    return this.geometry().rects;
  }
  /** The box around the covered text; a collapsed range reports its caret's box. */
  getBoundingClientRect(): DOMRect {
    return this.geometry().bound;
  }
  private geometry(): ValueRangeGeometry {
    this.sync();
    if (this.detached || this.control === null || valueRangeGeometryHook === null) {
      return { rects: [], bound: new DOMRect(0, 0, 0, 0) };
    }
    return valueRangeGeometryHook(this.control, this.start, this.end);
  }

  /** Collapses the range when its control is gone or no longer covers value text. */
  private sync(): void {
    if (this.detached) return;
    const c = this.control;
    if (c === null) { this.disconnect(); return; }
    if (!valueRangeSupported(c)) { this.disconnect(); return; }
    // Changing an input's type changes what its value is, so a range over the old value lets go.
    if (c instanceof HTMLInputElement && this.inputType !== null && c.type.toLowerCase() !== this.inputType) {
      this.disconnect();
      return;
    }
    if (c.isConnected) this.wasConnected = true;
    else if (this.wasConnected) { this.disconnect(); return; }
    if (this.owner !== null && c.ownerDocument !== this.owner) { this.disconnect(); return; }
    // A change the edit hooks didn't see (textContent, say) still can't leave an offset past the
    // end of the value.
    const n = c instanceof HTMLTextAreaElement || c instanceof HTMLInputElement ? c.value.length : 0;
    if (this.start > n) this.start = n;
    if (this.end > n) this.end = n;
    if (this.end < this.start) this.end = this.start;
  }
}

/** The value range a control's createValueRange() makes. */
function createValueRangeFor(control: Element, start: any, end: any): OpaqueRange {
  if (start === undefined || end === undefined) {
    throw new TypeError("Failed to execute 'createValueRange': 2 arguments required, but only " +
      (start === undefined && end === undefined ? "0" : "1") + " present.");
  }
  if (!(control instanceof HTMLInputElement) && !(control instanceof HTMLTextAreaElement)) {
    throw new Error("NotSupportedError: Failed to execute 'createValueRange': the element has no value text.");
  }
  if (!valueRangeSupported(control)) {
    throw new Error("NotSupportedError: Failed to execute 'createValueRange': the element has no value text.");
  }
  const n = control.value.length;
  const s = Number.isFinite(Number(start)) ? Math.trunc(Number(start)) : 0;
  const e = Number.isFinite(Number(end)) ? Math.trunc(Number(end)) : 0;
  if (s < 0 || e < 0 || s > n || e > n) {
    throw new Error("IndexSizeError: Failed to execute 'createValueRange': the range [" + s + ", " + e +
      ") is outside the value's length (" + n + ").");
  }
  const range = new OpaqueRange(control, "value-range");
  range.setBoundaries(s, e);
  control.valueRanges.push(range);
  return range;
}

// The live ranges a script made, which every edit to the text moves with it. Like the live
// collections, they are a linked list through the ranges themselves (scriptc copies an array of
// objects structurally when it crosses into dynamic code, issue 44).
let liveRangeHead: Range | null = null;

/** Forgets the live ranges of the page that just ended (the WPT runner reuses the process). */
export function clearLiveRanges(): void {
  liveRangeHead = null;
}

/** Moves the live ranges' boundaries past a replace-data edit of `node`. */
function moveLiveRanges(node: Node, offset: number, count: number, delta: number): void {
  let r: Range | null = liveRangeHead;
  while (r !== null) {
    const next = r.nextLive;
    if (r.startContainer === node) r.startOffset = moveRangeBoundary(r.startOffset, offset, count, delta);
    if (r.endContainer === node) r.endOffset = moveRangeBoundary(r.endOffset, offset, count, delta);
    r = next;
  }
}

/** Whether `node` is `ancestor` or sits inside it. */
function isInSubtree(node: Node, ancestor: Node): boolean {
  let n: Node | null = node;
  while (n !== null) {
    if (n === ancestor) return true;
    n = n.parentNode;
  }
  return false;
}

/** Moves the live ranges' boundaries past the removal of `child` from `parent` at `index`. */
function liveRangesSawRemoval(parent: Node, child: Node, index: number): void {
  let r: Range | null = liveRangeHead;
  while (r !== null) {
    const next = r.nextLive;
    if (isInSubtree(r.startContainer, child)) {
      r.startContainer = parent;
      r.startOffset = index;
    } else if (r.startContainer === parent && r.startOffset > index) {
      r.startOffset -= 1;
    }
    if (isInSubtree(r.endContainer, child)) {
      r.endContainer = parent;
      r.endOffset = index;
    } else if (r.endContainer === parent && r.endOffset > index) {
      r.endOffset -= 1;
    }
    r = next;
  }
}

/**
 * A range: two points in the document's text, each a text node or an element and an offset.
 * Geometry (getClientRects and getBoundingClientRect) isn't here yet: a range answers about the
 * text it covers, which is what copying and the Selection API's readers need.
 */
export class Range extends AbstractRange {
  get [Symbol.toStringTag](): string { return "Range"; }
  startOffset = 0;
  endOffset = 0;
  /** The next live range in the registry, so a detach can unlink this one. */
  nextLive: Range | null = null;

  // `new Range()` is a live range at the document's start, as in a browser; giving a start or an
  // end that isn't a node uses the document for it, so a page's `new Range()` call form works.
  constructor(start: Node | null = null, startOffset: number = 0, end: Node | null = null, endOffset: number = 0) {
    super("abstract-range");
    const a: Node = start ?? document.documentElement;
    const b: Node = end ?? a;
    this.startContainer = a;
    this.startOffset = startOffset;
    this.endContainer = b;
    this.endOffset = endOffset;
    this.nextLive = liveRangeHead;
    liveRangeHead = this;
  }

  get collapsed(): boolean {
    return this.startContainer === this.endContainer && this.startOffset === this.endOffset;
  }

  /** The tree the range's boundaries are in: the document, or a shadow root. */
  get rangeRoot(): Node {
    return this.startContainer.getRootNode();
  }

  get commonAncestorContainer(): Node {
    let a: Node | null = this.startContainer;
    while (a !== null) {
      let b: Node | null = this.endContainer;
      while (b !== null) {
        if (b === a) return a;
        b = b.parentNode;
      }
      a = a.parentNode;
    }
    return document.documentElement;
  }

  setStart(node?: any, offset?: any): void {
    const n = requireNode(node, "setStart");
    if (offset === undefined) {
      throw new TypeError("Failed to execute 'setStart' on 'Range': 2 arguments required, but only 1 present.");
    }
    this.startContainer = n;
    this.startOffset = Number(offset);
  }
  setEnd(node?: any, offset?: any): void {
    const n = requireNode(node, "setEnd");
    if (offset === undefined) {
      throw new TypeError("Failed to execute 'setEnd' on 'Range': 2 arguments required, but only 1 present.");
    }
    this.endContainer = n;
    this.endOffset = Number(offset);
  }
  setStartAfter(node?: any): void {
    const n = requireNode(node, "setStartAfter");
    if (n.parentNode !== null) this.setStart(n.parentNode, childIndex(n) + 1);
  }
  setEndAfter(node?: any): void {
    const n = requireNode(node, "setEndAfter");
    if (n.parentNode !== null) this.setEnd(n.parentNode, childIndex(n) + 1);
  }
  setStartBefore(node?: any): void {
    const n = requireNode(node, "setStartBefore");
    if (n.parentNode !== null) this.setStart(n.parentNode, childIndex(n));
  }
  setEndBefore(node?: any): void {
    const n = requireNode(node, "setEndBefore");
    if (n.parentNode !== null) this.setEnd(n.parentNode, childIndex(n));
  }
  selectNode(node?: any): void {
    const n = requireNode(node, "selectNode");
    if (n.parentNode === null) {
      throw new Error("InvalidNodeTypeError: Failed to execute 'selectNode' on 'Range': the node has no parent.");
    }
    this.setStartBefore(n);
    this.setEndAfter(n);
  }
  selectNodeContents(node?: any): void {
    const n = requireNode(node, "selectNodeContents");
    // A doctype has no contents a range can cover.
    if (n.nodeType === 10) {
      throw new Error("InvalidNodeTypeError: Failed to execute 'selectNodeContents' on 'Range': the node is a doctype.");
    }
    // A node that holds its content as one run of text gets the text child a browser has, so the
    // range covers the text rather than collapsing at its start.
    materializeText(n);
    this.startContainer = n;
    this.startOffset = 0;
    this.endContainer = n;
    this.endOffset = pointLength(n);
  }
  collapse(toStart: boolean = false): void {
    if (toStart) {
      this.endContainer = this.startContainer;
      this.endOffset = this.startOffset;
    } else {
      this.startContainer = this.endContainer;
      this.startOffset = this.endOffset;
    }
  }
  cloneRange(): Range {
    return new Range(this.startContainer, this.startOffset, this.endContainer, this.endOffset);
  }
  /** Takes the range out of the live registry: an edit no longer moves it. */
  detach(): void {
    if (liveRangeHead === this) {
      liveRangeHead = this.nextLive;
      this.nextLive = null;
      return;
    }
    let r: Range | null = liveRangeHead;
    while (r !== null && r.nextLive !== null) {
      if (r.nextLive === this) {
        r.nextLive = this.nextLive;
        this.nextLive = null;
        return;
      }
      r = r.nextLive;
    }
  }
  toString(): string {
    const root = this.commonAncestorContainer;
    const runs = textRuns(root);
    const a = pointAt(runs, this.startContainer, this.startOffset);
    const b = pointAt(runs, this.endContainer, this.endOffset);
    const from = Math.min(a, b), to = Math.max(a, b);
    let out = "";
    for (const r of runs) {
      const s = Math.max(from, r.at) - r.at;
      const e = Math.min(to, r.at + r.text.length) - r.at;
      if (e > s) out += r.text.slice(s, e);
    }
    return out;
  }
  static readonly START_TO_START = 0;
  static readonly START_TO_END = 1;
  static readonly END_TO_END = 2;
  static readonly END_TO_START = 3;
  readonly START_TO_START = 0;
  readonly START_TO_END = 1;
  readonly END_TO_END = 2;
  readonly END_TO_START = 3;

  startContainer: Node;
  endContainer: Node;

  private root(): Node {
    return this.startContainer.getRootNode();
  }

  private setPoint(start: boolean, node: Node, offset: number): void {
    const off = Math.floor(offset);
    if (off < 0 || off > pointLength(node)) {
      throw new Error(`IndexSizeError: ${start ? "setStart" : "setEnd"}: the offset ${off} is larger than the node's length.`);
    }
    if (node.nodeType === 10) throw new Error("InvalidNodeTypeError: a doctype is not a range boundary.");
    const at = start ? this.endContainer : this.startContainer;
    const atOff = start ? this.endOffset : this.startOffset;
    if (start) {
      this.startContainer = node;
      this.startOffset = off;
    } else {
      this.endContainer = node;
      this.endOffset = off;
    }
    // A range whose start passed its end collapses to the point that moved.
    const c = comparePoints(this.startContainer, this.startOffset, this.endContainer, this.endOffset);
    if (c > 0) {
      if (start) {
        this.endContainer = node;
        this.endOffset = off;
      } else {
        this.startContainer = node;
        this.startOffset = off;
      }
    }
  }

  compareBoundaryPoints(how?: any, source?: any): number {
    if (source === undefined || source === null || !(source instanceof Range)) {
      throw new TypeError("Failed to execute 'compareBoundaryPoints' on 'Range': parameter 2 is not of type 'Range'.");
    }
    const mode = Number(how);
    if (mode !== Range.START_TO_START && mode !== Range.START_TO_END &&
      mode !== Range.END_TO_END && mode !== Range.END_TO_START) {
      throw new TypeError("Failed to execute 'compareBoundaryPoints' on 'Range': the comparison mode is not one of START_TO_START, START_TO_END, END_TO_END or END_TO_START.");
    }
    let a: Node, ao: number, b: Node, bo: number;
    if (mode === Range.START_TO_START) { a = this.startContainer; ao = this.startOffset; b = source.startContainer; bo = source.startOffset; }
    else if (mode === Range.START_TO_END) { a = this.endContainer; ao = this.endOffset; b = source.startContainer; bo = source.startOffset; }
    else if (mode === Range.END_TO_END) { a = this.endContainer; ao = this.endOffset; b = source.endContainer; bo = source.endOffset; }
    else { a = this.startContainer; ao = this.startOffset; b = source.endContainer; bo = source.endOffset; }
    return comparePoints(a, ao, b, bo);
  }

  comparePoint(node?: any, offset: number = 0): number {
    const n = requireNode(node, "comparePoint");
    const off = Math.floor(offset);
    if (n.getRootNode() !== this.root()) throw new Error("WrongDocumentError: the node is in another tree.");
    if (off < 0 || off > pointLength(n)) throw new Error("IndexSizeError: comparePoint: the offset is larger than the node's length.");
    if (comparePoints(n, off, this.startContainer, this.startOffset) < 0) return -1;
    if (comparePoints(n, off, this.endContainer, this.endOffset) > 0) return 1;
    return 0;
  }

  isPointInRange(node?: any, offset: number = 0): boolean {
    const n = requireNode(node, "isPointInRange");
    if (n.getRootNode() !== this.root()) return false;
    const off = Math.floor(offset);
    if (off < 0 || off > pointLength(n)) return false;
    return comparePoints(n, off, this.startContainer, this.startOffset) >= 0 &&
      comparePoints(n, off, this.endContainer, this.endOffset) <= 0;
  }

  intersectsNode(node?: any): boolean {
    const n = requireNode(node, "intersectsNode");
    if (n.getRootNode() !== this.root()) return false;
    const parent = n.parentNode;
    if (parent === null) return true;
    const at = rangeChildren(parent).indexOf(n);
    return comparePoints(parent, at, this.endContainer, this.endOffset) < 0 &&
      comparePoints(parent, at + 1, this.startContainer, this.startOffset) > 0;
  }

  /** The text the range covers, as a browser's toString() gives it. */
  private prepareStart(): { parent: Node; index: number } {
    const c = this.startContainer;
    if (c.nodeType === 3 || c.nodeType === 4) {
      const text = c as Text;
      const at = this.startOffset;
      if (at === 0) return { parent: text.parentNode as Node, index: rangeChildren(text.parentNode as Node).indexOf(text) };
      if (at === text.ownText.length) return { parent: text.parentNode as Node, index: rangeChildren(text.parentNode as Node).indexOf(text) + 1 };
      const rest = text.splitText(at);
      this.endContainer = rest;
      this.endOffset = 0;
      this.startOffset = at;
      this.startContainer = text;
      return { parent: rest.parentNode as Node, index: rangeChildren(rest.parentNode as Node).indexOf(rest) };
    }
    return { parent: c, index: this.startOffset };
  }

  insertNode(node?: any): void {
    const n = requireNode(node, "insertNode");
    const target = this.prepareStart();
    target.parent.insertBefore(n, rangeChildren(target.parent)[target.index] ?? null);
  }

  /** Collects the nodes the range selects: partial text at the ends, whole subtrees inside. */
  private selected(): { node: Node; from: number; to: number; whole: boolean }[] {
    const out: { node: Node; from: number; to: number; whole: boolean }[] = [];
    if (this.collapsed) return out;
    const end = { node: this.endContainer, off: this.endOffset };
    const start = { node: this.startContainer, off: this.startOffset };
    // A node outside the range's own tree (the document's content around a shadow root, say)
    // is never contained in the range.
    const root = this.startContainer.getRootNode();
    const walk = (node: Node): void => {
      if (node.getRootNode() !== root) return;
      if (comparePoints(node, pointLength(node), end.node, end.off) <= 0 &&
        node !== start.node && node !== end.node &&
        !isInSubtree(start.node, node) && !isInSubtree(end.node, node)) {
        // Entirely inside the range. A node that holds one of the boundaries isn't: the boundary
        // cuts it, and the walk has to descend into it for the part the range covers.
        out.push({ node, from: 0, to: pointLength(node), whole: true });
        return;
      }
      const t = node.nodeType;
      if (t === 3 || t === 4 || t === 7) {
        const len = node.ownText.length;
        const from = node === start.node ? start.off : 0;
        const to = node === end.node ? end.off : len;
        if (to > from || (node === start.node && node === end.node)) out.push({ node, from, to, whole: false });
        return;
      }
      for (const c of rangeChildren(node)) {
        // Skip a child that ends before the range starts, and one that starts at or after the
        // range ends: only what lies between the boundaries is selected.
        if (comparePoints(c, pointLength(c), start.node, start.off) < 0) continue;
        if (comparePoints(c, 0, end.node, end.off) >= 0) continue;
        walk(c);
      }
    };
    walk(this.commonAncestorContainer);
    return out;
  }

  deleteContents(): void {
    if (this.collapsed) return;
    const parts = this.selected();
    for (const part of parts) {
      if (part.whole) {
        if (part.node.parentNode !== null) part.node.parentNode.removeChild(part.node);
      } else if (part.node.nodeType === 3 || part.node.nodeType === 4 || part.node.nodeType === 7) {
        const t = part.node as unknown as { ownText: string; data: any };
        t.data = t.ownText.slice(0, part.from) + t.ownText.slice(part.to);
      }
    }
    this.collapse(true);
  }

  /** Whether a node's whole subtree lies inside the range: both its boundary points do. */
  private containsWhole(node: Node): boolean {
    if (node.getRootNode() !== this.startContainer.getRootNode()) return false;
    return comparePoints(this.startContainer, this.startOffset, node, 0) < 0 &&
      comparePoints(node, pointLength(node), this.endContainer, this.endOffset) < 0;
  }

  /** Clones the parts of `source`'s children the range covers into `target`, keeping the tree. */
  private cloneCovered(source: Node, target: Node): void {
    for (const child of rangeChildren(source)) {
      if ((child.isTextNode || child.nodeType === 7) && (child === this.startContainer || child === this.endContainer)) {
        const from = child === this.startContainer ? this.startOffset : 0;
        const to = child === this.endContainer ? this.endOffset : child.ownText.length;
        const lo = Math.max(0, Math.min(from, to));
        const hi = Math.min(child.ownText.length, Math.max(from, to));
        // A processing instruction keeps its node in the clone even when the range's part of
        // its data is empty; a text node contributes nothing then.
        if (hi > lo || child.nodeType === 7) {
          if (child.nodeType === 7) target.appendChild(new ProcessingInstruction((child as ProcessingInstruction).target, child.ownText.slice(lo, hi)));
          else target.appendChild(new Text(child.ownText.slice(lo, hi)));
        }
      } else if (this.containsWhole(child)) {
        target.appendChild(child.cloneNode(true));
      } else if (isInSubtree(this.startContainer, child) || isInSubtree(this.endContainer, child)) {
        // A boundary is deeper inside this child: keep the child, and fill in what it covers. A
        // host whose shadow is clonable keeps its shadow, as a deep clone of it would.
        const copy = child.cloneNode(false);
        if (child instanceof Element && copy instanceof Element) child.cloneClonableShadowInto(copy);
        target.appendChild(copy);
        this.cloneCovered(child, copy);
      }
    }
  }

  cloneContents(): DocumentFragment {
    const fragment = new DocumentFragment();
    if (this.collapsed) return fragment;
    // A range whose ends are in different trees (one in a shadow root) has nothing between them:
    // the tree order that would name the content doesn't exist.
    if (this.endContainer.getRootNode() !== this.startContainer.getRootNode()) return fragment;
    const startNode = this.startContainer;
    if ((startNode.isTextNode || startNode.nodeType === 7) && startNode === this.endContainer) {
      const lo = Math.max(0, Math.min(this.startOffset, this.endOffset));
      const hi = Math.min(startNode.ownText.length, Math.max(this.startOffset, this.endOffset));
      if (hi > lo) {
        if (startNode.nodeType === 7) fragment.appendChild(new ProcessingInstruction((startNode as ProcessingInstruction).target, startNode.ownText.slice(lo, hi)));
        else fragment.appendChild(new Text(startNode.ownText.slice(lo, hi)));
      }
      return fragment;
    }
    this.cloneCovered(this.commonAncestorContainer, fragment);
    return fragment;
  }

  extractContents(): DocumentFragment {
    if (this.collapsed) return new DocumentFragment();
    // What the range covers, cloned, and then removed from the tree.
    const fragment = this.cloneContents();
    this.deleteContents();
    return fragment;
  }

  surroundContents(newParent?: any): void {
    const parent = requireNode(newParent, "surroundContents");
    const check = (node: Node): void => {
      if (node.nodeType === 3 || node.nodeType === 4) {
        const off = node === this.startContainer ? this.startOffset : this.endOffset;
        if (off !== 0 && off !== pointLength(node)) {
          throw new Error("InvalidStateError: Failed to execute 'surroundContents' on 'Range': The Range has partially selected a non-Text node.");
        }
      }
    };
    check(this.startContainer);
    check(this.endContainer);
    const fragment = this.extractContents();
    while (parent.firstChild !== null) parent.removeChild(parent.firstChild);
    parent.appendChild(fragment);
    this.insertNode(parent);
    this.selectNode(parent);
  }

  createContextualFragment(html: string): DocumentFragment {
    const fragment = new DocumentFragment();
    for (const n of parseFragment(String(html))) fragment.appendChild(n);
    return fragment;
  }

  /**
   * The rects the range covers: one per line it spans, each as wide as the characters on that line
   * and as tall as the font box, in viewport coordinates.
   */
  getClientRects(): DOMRect[] {
    // A read forces the pending style and layout, as a browser's geometry readers do: the rects
    // are the fragments the line boxes made, and a text node added since the last frame has none
    // until it is laid out.
    flushLayoutHook();
    const out: DOMRect[] = [];
    const runs = textRuns(this.commonAncestorContainer);
    const a = pointAt(runs, this.startContainer, this.startOffset);
    const b = pointAt(runs, this.endContainer, this.endOffset);
    const from = Math.min(a, b);
    const to = Math.max(a, b);
    for (const r of runs) {
      const s = Math.max(from, r.at) - r.at;
      const e = Math.min(to, r.at + r.text.length) - r.at;
      if (e > s) for (const rect of textRunRects(r.node, s, e)) out.push(rect);
      if (r.at >= to) break;
    }
    return out;
  }

  /** The union of the range's rects, or an empty one when it covers no text. */
  getBoundingClientRect(): DOMRect {
    const rects = this.getClientRects();
    if (rects.length === 0) return new DOMRect(0, 0, 0, 0);
    let left = rects[0].left;
    let top = rects[0].top;
    let right = rects[0].right;
    let bottom = rects[0].bottom;
    for (const r of rects) {
      if (r.left < left) left = r.left;
      if (r.top < top) top = r.top;
      if (r.right > right) right = r.right;
      if (r.bottom > bottom) bottom = r.bottom;
    }
    return new DOMRect(left, top, right - left, bottom - top);
  }
}

// ---------------------------------------------------------------------------
// Ranges

/** The children of a node that a boundary point can sit between (generated boxes aren't in it). */
function rangeChildren(node: Node): Node[] {
  const out: Node[] = [];
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) out.push(c);
  return out;
}

/** The length a boundary offset is measured against: data length, or the child count. */
function pointLength(node: Node): number {
  const t = node.nodeType;
  if (t === 3 || t === 4 || t === 7 || t === 8) return node.ownText.length;
  // A boundary offset counts child nodes, and an element whose content is one run of text has
  // the #text child a browser has: give it that child, as firstChild and childNodes do.
  materializeText(node);
  return rangeChildren(node).length;
}

/** Whether `a` is `b` or an ancestor of it. */
function inclusiveAncestor(a: Node, b: Node): boolean {
  let n: Node | null = b;
  while (n !== null) {
    if (n === a) return true;
    n = n.parentNode;
  }
  return false;
}

/** The child of `ancestor` that leads to `node`. */
function childToward(ancestor: Node, node: Node): Node {
  let n: Node = node;
  while (n.parentNode !== ancestor) n = n.parentNode as Node;
  return n;
}

/** The order of two boundary points: -1 before, 0 the same, 1 after. */
function comparePoints(nodeA: Node, offA: number, nodeB: Node, offB: number): number {
  if (nodeA === nodeB) return offA === offB ? 0 : offA < offB ? -1 : 1;
  if (inclusiveAncestor(nodeA, nodeB)) {
    const c = childToward(nodeA, nodeB);
    return offA <= rangeChildren(nodeA).indexOf(c) ? -1 : 1;
  }
  if (inclusiveAncestor(nodeB, nodeA)) {
    const c = childToward(nodeB, nodeA);
    return rangeChildren(nodeB).indexOf(c) < offB ? -1 : 1;
  }
  // Neither node contains the other: bring a and b to the same depth, then walk them up to the
  // common parent; the children there give the order.
  let a: Node | null = nodeA;
  let b: Node | null = nodeB;
  let da = 0;
  let db = 0;
  for (let n: Node | null = a; n !== null; n = n.parentNode) da++;
  for (let n: Node | null = b; n !== null; n = n.parentNode) db++;
  while (da > db && a !== null) { a = a.parentNode; da--; }
  while (db > da && b !== null) { b = b.parentNode; db--; }
  while (a !== null && b !== null && a !== b && a.parentNode !== b.parentNode) {
    a = a.parentNode;
    b = b.parentNode;
  }
  // Boundaries in different trees (a shadow root's and the document's) have no order between
  // them; the range operations keep to the range's own root, so 0 is as good as any answer.
  if (a === null || b === null) return 0;
  if (a === b) return 0;
  const parent = a.parentNode;
  if (parent === null) return 0;
  return rangeChildren(parent).indexOf(a) < rangeChildren(parent).indexOf(b) ? -1 : 1;
}

/** A range: the content between two boundary points, and the operations over it. */
/**
 * The rects a run of one text node covers: one per line, each spanning the characters of that line
 * the range holds. A box's own text leaves no fragments, only the lines it wrapped, so those are
 * read from the box; text inside inline content reads the fragments of the line it sits on.
 */
function textRunRects(node: Node, from: number, to: number): DOMRect[] {
  const parent = node.parentElement;
  if (parent === null) return [];
  // A text node that is a block's own text has the block's fragments, which are recorded on the
  // block itself; fragmentHolder() looks above its argument, so the parent is checked first.
  const fragments = parent.fragKind.length > 0 ? parent : fragmentHolder(parent);
  return fragments !== null ? fragmentRects(fragments, node, from, to) : ownTextRects(parent, node, from, to);
}

/** The rects a range of a text node's characters covers, one per line of its holder. */
function fragmentRects(holder: Node, node: Node, from: number, to: number): DOMRect[] {
  // Layout records a text child's fragments against the element it is the text of: an element's
  // own text is its text in this model, so a text node is matched through its parent.
  const owner: Node = node.isTextNode && node.parentElement !== null ? node.parentElement : node;
  const origin = viewportOrigin(holder);
  const size = node.sv[P.P_FONT_SIZE];
  const weight = node.sv[P.P_FONT_WEIGHT];
  const out: DOMRect[] = [];
  let at = 0;
  let line = -1;
  let left = Infinity;
  let right = -Infinity;
  let top = 0;
  const flush = (): void => {
    if (right > left) out.push(frameRect(holder, origin, left, top, right - left, fontBoxHeight(node)));
    left = Infinity;
    right = -Infinity;
  };
  for (let i = 0; i < holder.fragKind.length; i++) {
    if (holder.fragOwner[i] !== owner) continue;
    const text = holder.fragText[i];
    const start = at;
    at += text.length;
    if (at <= from || start >= to) continue;
    if (holder.fragLine[i] !== line) {
      flush();
      line = holder.fragLine[i];
      top = holder.fragTop[i] + fontBoxLeading(node);
    }
    // The part of this fragment the range holds, measured from its start.
    const a = Math.max(from, start) - start;
    const b = Math.min(to, at) - start;
    const x0 = holder.fragX[i] + (a > 0 ? measure(text.slice(0, a), size, weight) : 0);
    const x1 = holder.fragX[i] + (b < text.length ? measure(text.slice(0, b), size, weight) : holder.fragW[i]);
    if (x0 < left) left = x0;
    if (x1 > right) right = x1;
  }
  flush();
  return out;
}

/**
 * The rects a range of a box's own text covers: the lines the box wrapped are the only record of
 * where its text went, so each line the range spans gives a rect the width of the characters it
 * holds. A line that dropped the white space at its end is matched against the text by walking
 * both, which keeps the offsets right.
 */
function ownTextRects(parent: Node, node: Node, from: number, to: number): DOMRect[] {
  let holder: Node | null = parent;
  while (holder !== null && holder.lines.length === 0) holder = holder.parentElement;
  if (holder === null) return [];
  const origin = viewportOrigin(holder);
  const lh = lineHeightPx(holder);
  const size = holder.sv[P.P_FONT_SIZE];
  const weight = holder.sv[P.P_FONT_WEIGHT];
  const text = node.ownText;
  const vturn = holder.vtext !== 0;
  const m = usedWritingMode(holder);
  const vlr = m === P.WM_VERTICAL_LR || m === P.WM_SIDEWAYS_LR;
  const inner = vturn ? holder.contentH : holder.contentW;
  const align = lineAlign(holder);
  const blockStart = vlr ? holder.contentX : holder.w - holder.contentX - holder.contentW;
  const out: DOMRect[] = [];
  let at = 0;
  for (let i = 0; i < holder.lines.length && at < to; i++) {
    const line = holder.lines[i];
    const start = at;
    // Walk the line against the text: a white-space run the line dropped is stepped over.
    let k = 0;
    while (k < line.length && at < text.length) {
      if (text[at] === line[k]) k++;
      at++;
    }
    const s = Math.max(from, start) - start;
    const e = Math.min(to, at) - start;
    if (e <= s) continue;
    // Where the line starts in the frame, and how far along it the range's characters lie.
    const ind = i === 0 ? holder.textIndent : 0;
    const availW = inner - ind;
    let tx = ind;
    if (align === P.T_CENTER) tx = ind + (availW - holder.lineWidths[i]) / 2;
    else if (align === P.T_RIGHT) tx = ind + availW - holder.lineWidths[i];
    const x0 = tx + measure(line.slice(0, s), size, weight);
    const x1 = tx + measure(line.slice(0, e), size, weight);
    if (vturn) {
      // The font box sits inside the line box by the upper leading, on the block-start side here,
      // and the block offset is measured from that side whichever way the frame's block axis runs.
      const v = i * lh + fontBoxLeading(holder);
      out.push(frameRect(holder, origin, holder.contentY + x0, blockStart + v, x1 - x0, fontBoxHeight(holder)));
    } else {
      out.push(new DOMRect(origin[0] + x0, origin[1] + holder.contentY + i * lh + fontBoxLeading(holder),
        x1 - x0, fontBoxHeight(holder)));
    }
  }
  return out;
}

/** The child index of a node in its parent's list, -1 when it has no parent. */
/** The node's index among its parent's children a boundary point counts: the generated boxes a
 *  style made aren't children there, so they don't shift a sibling's index. */
function childIndex(node: Node): number {
  const p = node.parentNode;
  if (p === null) return -1;
  let i = 0;
  for (const c of p.kids) {
    if (c === node) return c.pseudoKind === P.PE_NONE ? i : -1;
    if (c.pseudoKind === P.PE_NONE) i++;
  }
  return -1;
}

/** Whether `inner` is `outer` or inside it (the popover code's `insideNode` narrows to Element). */
function insideNodeDeep(outer: Node, inner: Node): boolean {
  let n: Node | null = inner;
  while (n !== null) {
    if (n === outer) return true;
    n = n.parentNode;
  }
  return false;
}

/**
 * The document's selection: one range, as the Selection API keeps it here. A range added or
 * collapsed sets the anchor and focus to its ends; the text-level readers (`toString`,
 * `containsNode`) answer from the ranges' text, and painting a ::selection highlight is still to
 * come, so a selected stretch reads but doesn't show.
 */
export class Selection {
  get [Symbol.toStringTag](): string { return "Selection"; }
  private ranges: Range[] = [];
  private collapsedPoint: Node | null = null;
  private collapsedOffset = 0;

  get rangeCount(): number {
    return this.ranges.length;
  }
  get isCollapsed(): boolean {
    return this.ranges.length === 0 || (this.ranges.length === 1 && this.ranges[0].collapsed);
  }
  get type(): string {
    if (this.ranges.length === 0) return this.collapsedPoint === null ? "None" : "Caret";
    return this.isCollapsed ? "Caret" : "Range";
  }
  get anchorNode(): Node | null {
    if (this.ranges.length > 0) return this.ranges[0].startContainer;
    return this.collapsedPoint;
  }
  get anchorOffset(): number {
    if (this.ranges.length > 0) return this.ranges[0].startOffset;
    return this.collapsedOffset;
  }
  get focusNode(): Node | null {
    if (this.ranges.length > 0) return this.ranges[0].endContainer;
    return this.collapsedPoint;
  }
  get focusOffset(): number {
    if (this.ranges.length > 0) return this.ranges[0].endOffset;
    return this.collapsedOffset;
  }
  getRangeAt(i: number): Range {
    return this.ranges[i];
  }
  addRange(range: Range): void {
    this.ranges = [range];
    this.collapsedPoint = null;
  }
  removeRange(range: Range): void {
    this.ranges = this.ranges.filter((r) => r !== range);
  }
  removeAllRanges(): void {
    this.ranges = [];
    this.collapsedPoint = null;
  }
  empty(): void {
    this.removeAllRanges();
  }
  collapse(node?: Node | null, offset: number = 0): void {
    this.ranges = [];
    this.collapsedPoint = node ?? null;
    this.collapsedOffset = offset;
  }
  collapseToStart(): void {
    if (this.ranges.length === 0) return;
    const r = this.ranges[0];
    this.collapse(r.startContainer, r.startOffset);
  }
  collapseToEnd(): void {
    if (this.ranges.length === 0) return;
    const r = this.ranges[0];
    this.collapse(r.endContainer, r.endOffset);
  }
  extend(node: Node, offset: number = 0): void {
    const anchorNode = this.anchorNode, anchorOffset = this.anchorOffset;
    this.ranges = [new Range(anchorNode ?? node, anchorNode === null ? 0 : anchorOffset, node, offset)];
    this.collapsedPoint = null;
  }
  /** Sets the anchor and the focus in one call, over the range between them. */
  setBaseAndExtent(anchorNode: Node, anchorOffset: number, focusNode: Node, focusOffset: number): void {
    this.ranges = [new Range(anchorNode, anchorOffset, focusNode, focusOffset)];
    this.collapsedPoint = null;
  }
  selectAllChildren(node: Node): void {
    // As selectNodeContents: a node that holds its content as one run of text gets its text child
    // first, so the selection covers the text.
    materializeText(node);
    const r = new Range(node, 0, node, node.isTextNode ? node.ownText.length : rangeChildren(node).length);
    this.addRange(r);
  }
  containsNode(node: Node, partial: boolean = false): boolean {
    for (const r of this.ranges) {
      const root = r.commonAncestorContainer;
      const runs = textRuns(root);
      const a = pointAt(runs, r.startContainer, r.startOffset);
      const b = pointAt(runs, r.endContainer, r.endOffset);
      for (const run of runs) {
        if (run.node !== node) {
          if (partial && insideNodeDeep(node, run.node)) return true;
          continue;
        }
        if (partial ? run.text.length > 0 : false) return true;
        if (run.at >= Math.min(a, b) && run.at + run.text.length <= Math.max(a, b) && run.text.length > 0) return true;
      }
    }
    return false;
  }
  toString(): string {
    let out = "";
    for (const r of this.ranges) out += r.toString();
    return out;
  }
}

const selection = new Selection();

/**
 * The hooks the pointer's selection code uses to move the document's selection: a caret at a
 * point, or a range from where a drag began to where it is. An element offset counts that
 * element's own text, which is how a selection made by a pointer is held.
 */
/** The selection's text span in the document's character stream, or null when it is empty. */
export function selectionStreamRange(): [number, number] | null {
  if (selection.rangeCount === 0) return null;
  return rangeStreamSpan(selection.getRangeAt(0));
}

/** The document's text runs, rebuilt when the tree or its styles change. */
let cachedRuns: TextRun[] | null = null;
let cachedRunsVersion = -1;

function documentTextRuns(): TextRun[] {
  if (cachedRuns === null || cachedRunsVersion !== textVersion.n) {
    cachedRuns = textRuns(document.documentElement);
    cachedRunsVersion = textVersion.n;
  }
  return cachedRuns;
}

/**
 * The nodes whose text lies in the document stream's span [a, b), in stream order, or null when
 * there are more than `limit` of them.
 */
export function textOwnersBetween(a: number, b: number, limit: number): Node[] | null {
  const runs = documentTextRuns();
  // The first run that ends after a: runs are in stream order.
  let lo = 0;
  let hi = runs.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (runs[mid].at + runs[mid].text.length <= a) lo = mid + 1;
    else hi = mid;
  }
  const out: Node[] = [];
  for (let i = lo; i < runs.length && runs[i].at < b; i++) {
    if (runs[i].text.length === 0) continue;
    if (out.length >= limit) return null;
    out.push(runs[i].node);
  }
  return out;
}

/** A point's character offset in the document's text stream. */
export function textStreamIndex(node: Node, offset: number): number {
  return pointAt(documentTextRuns(), node, offset);
}

/** The document's whole text stream, as a text fragment searches it. */
export function documentTextStream(): string {
  let out = "";
  for (const r of documentTextRuns()) out += r.text;
  return out;
}

/**
 * The character span of a range in the document's text stream, or null for a collapsed one. The
 * selection and the Custom Highlight API both map the text they paint through this.
 */
export function rangeStreamSpan(r: AbstractRange): [number, number] | null {
  // A value range covers a control's value, whose text isn't in the document's text stream.
  if (!(r instanceof Range) || r.collapsed) return null;
  const runs = documentTextRuns();
  const a = pointAt(runs, r.startContainer, r.startOffset);
  const b = pointAt(runs, r.endContainer, r.endOffset);
  return a === b ? null : [Math.min(a, b), Math.max(a, b)];
}

export const selectionState = {
  collapse(node: Node | null, offset: number): void {
    selection.collapse(node, offset);
  },
  setPoints(a: { el: Node; offset: number }, b: { el: Node; offset: number }): void {
    selection.addRange(new Range(a.el, a.offset, b.el, b.offset));
  },
};

/**
 * Forgets the document's selection. A browser gives each document a selection of its own, empty
 * until a script makes one, so a runner that mounts page after page in one process calls this
 * between them: the last page's selection would otherwise point at nodes that are gone.
 */
export function resetSelection(): void {
  selection.collapse(null, 0);
}

// ---------------------------------------------------------------------------
// Window

/**
 * The window object, which runtime/window.ts owns and registers here when it loads. The import
 * is type-only: the window module imports the DOM for its values, and the DOM needs only the
 * window's type, so the two modules don't depend on each other's values.
 */
let defaultView: Window | null = null;

/** The page's own encoding, from its markup (see compiler/html.ts pageCharset). */
let pageCharset = "UTF-8";

/** Called by mount() with the charset its tables carry. */
export function setPageCharset(charset: string): void {
  pageCharset = charset;
}

/** Called by runtime/window.ts once the window object exists. */
export function setDefaultView(view: Window): void {
  defaultView = view;
}

// ---------------------------------------------------------------------------
// Document

/** DOMImplementation: the document factory a browser's `document.implementation` is. */
export class DOMImplementation {
  get [Symbol.toStringTag](): string { return "DOMImplementation"; }
  /** The document this implementation belongs to; null for the module-level one. */
  readonly doc: Document | null;

  constructor(doc: any = undefined) {
    // A script may not build one (the no-argument call leaves doc undefined); a document passes
    // itself, and the module-level implementation passes "module" for a null document.
    if (doc === undefined) throw new TypeError("Illegal constructor");
    this.doc = typeof doc === "string" ? null : doc;
  }

  /** Every feature a browser still answers about (hasFeature is kept only for old callers). */
  hasFeature(): boolean {
    return true;
  }

  /**
   * The doctype factory a script reaches through document.implementation. A doctype's name is
   * taken as given; only a name that cannot stand in markup is refused.
   */
  createDocumentType(name: any, publicId: any = "", systemId: any = ""): DocumentType {
    const qualified = String(name);
    const dt = new DocumentType(qualified, publicId === null ? "" : String(publicId), systemId === null ? "" : String(systemId));
    dt.owner = this.doc;
    return dt;
  }

  createHTMLDocument(title?: any): Document {
    const doc = new HTMLDocument();
    const html = doc.createElement("html");
    const head = doc.createElement("head");
    const body = doc.createElement("body");
    html.appendChild(head);
    html.appendChild(body);
    doc.appendChild(doc.implementation.createDocumentType("html", "", ""));
    doc.appendChild(html);
    doc.documentElement = html;
    doc.body = body;
    doc.headEl = head;
    if (title !== undefined) {
      const t = doc.createElement("title");
      t.textContent = String(title);
      head.appendChild(t);
    }
    return doc;
  }

  /** A document for XML: no html or body box, no implied elements. */
  createDocument(namespace: any, qualifiedName: any, _doctype: Node | null = null): Document {
    const doc = new XMLDocument();
    // A null qualifiedName makes no root element, as a browser's does.
    const name = qualifiedName === null || qualifiedName === undefined ? "" : String(qualifiedName);
    if (name !== "") {
      const el = doc.createElement(name);
      el.namespaceURI = namespace;
      const colon = name.indexOf(":");
      if (colon > 0) {
        el.prefix = name.slice(0, colon);
        el.localName = name.slice(colon + 1);
      }
      doc.documentElement = el;
      el.parentNode = doc;
      doc.kids.push(el);
    }
    return doc;
  }
}

export const implementation = new DOMImplementation("module");

/**
 * One @font-face as document.fonts reports it: every face a page declares is already registered
 * with the host when it mounts, so its status is "loaded" and load() resolves with it.
 */
export class FontFace {
  get [Symbol.toStringTag](): string { return "FontFace"; }
  family: string;
  weight = "normal";
  style = "normal";
  status = "loaded";
  constructor(family: string) {
    this.family = family;
  }
  load(): Promise<FontFace> {
    return new Promise<FontFace>((resolve) => resolve(this));
  }
}

/** The document's fonts: the faces the page declares, ready as soon as it is mounted. */
export class FontFaceSet extends EventTarget {
  get [Symbol.toStringTag](): string { return "FontFaceSet"; }
  private faces: FontFace[] = [];
  /** Resolves once the page's faces are registered, which mount has already done. */
  readonly ready: Promise<FontFaceSet>;
  status = "loaded";
  constructor() {
    super();
    this.ready = new Promise<FontFaceSet>((resolve) => resolve(this));
  }
  get size(): number { return this.faces.length; }
  get length(): number { return this.faces.length; }
  [Symbol.iterator](): Iterator<FontFace> {
    return this.faces[Symbol.iterator]();
  }
  forEach(fn: (face: FontFace) => void): void {
    this.faces.forEach(fn);
  }
  /** A face whose family the page declares, or none; nothing has to be fetched. */
  load(font?: string, _text?: string): Promise<FontFace[]> {
    const wanted = font === undefined ? "" : font.trim().toLowerCase().replace(/^['"]|['"]$/g, "");
    const match = this.faces.filter((f) => wanted === "" || wanted.indexOf(f.family) >= 0);
    const out = match.length > 0 ? match : this.faces.slice();
    return new Promise<FontFace[]>((resolve) => resolve(out));
  }
  check(_font?: string, _text?: string): boolean { return this.faces.length > 0; }
  /** Fills the set from the app's families; mounting a new page starts it over. */
  setFaces(families: string[]): void {
    this.faces = families.map((family) => new FontFace(family));
    // A browser fires loadingdone once the faces are ready, and again on a later sweep that
    // changed them; the page's faces are all local, so registering them is the whole load. A
    // listener added when the page mounts runs after this first sweep, whatever it asks for.
    if (this.listeners.get("loadingdone") !== undefined) this.dispatchEvent(new Event("loadingdone"));
  }
}

export class Document extends Node {
  get [Symbol.toStringTag](): string { return "Document"; }
  documentElement: HTMLElement = newElementFor("html", "", "", [], 0, false);

  /** A document's listeners are typed by DocumentEventMap, as the DOM lib types them. */
  addEventListener<K extends keyof DocumentEventMap>(type: K,
    listener: (event: DocumentEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    super.addEventListener(type, listener, options);
  }
  removeEventListener<K extends keyof DocumentEventMap>(type: K,
    listener: (event: DocumentEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    super.removeEventListener(type, listener, options);
  }
  /** A document is its own node document, so nodes inserted into it are adopted by it. */
  get nodeDocument(): Document {
    return this;
  }
  // The body is read from the tree (the first body or frameset child of the root), so removing
  // or adding one shows up at once; an XML document has none.
  // lib.dom declares `body: HTMLElement`, and a TypeScript page must be able to write
  // `document.body.appendChild(...)` as it would elsewhere, so the getter has that type. A
  // document with no body (an XML root, or none yet) answers its root element, which is the
  // closest a non-null answer can be; browsers answer null there, which scriptc can't represent
  // in this return type.
  get body(): HTMLElement {
    const root = this.rootChild();
    if (root === null) return this.documentElement;
    // The body belongs to an html root in the HTML namespace (an XHTML document included).
    if (root.localName !== "html" || root.namespaceURI !== "http://www.w3.org/1999/xhtml") return this.documentElement;
    for (const k of root.kids) {
      if (!k.isElementNode) continue;
      const el = k as Element;
      if (el.namespaceURI !== "http://www.w3.org/1999/xhtml") continue;
      if ((el.localName === "body" || el.localName === "frameset") && el instanceof HTMLElement) return el;
    }
    return this.documentElement;
  }
  set body(value: HTMLElement) {
    // A value that isn't an element (null included) is a TypeError; an element that isn't a body
    // or frameset can't be the body.
    if (!(value instanceof Node) || value.nodeType !== 1) {
      throw new TypeError("Failed to set the 'body' property on 'Document': The value provided is not an element.");
    }
    const el = value as Element;
    if (el.localName !== "body" && el.localName !== "frameset") {
      throw new Error("HierarchyRequestError: Failed to set the 'body' property on 'Document': The new body element is of type '" + el.localName + "'.");
    }
    const root = this.rootChild();
    if (root === null) {
      throw new Error("HierarchyRequestError: Failed to set the 'body' property on 'Document': The document has no document element.");
    }
    // A new body replaces the body or frameset the root already has.
    for (const k of root.kids.slice()) {
      if (!k.isElementNode || k === el) continue;
      const existing = k as Element;
      if (existing.localName === "body" || existing.localName === "frameset") root.removeChild(existing);
    }
    if (el.parentNode !== root) root.appendChild(el);
  }
  titleText = "";
  /** "loading" until the page's scripts have run, then "complete" (see dispatchLoad). */
  readyState = "loading";
  /** The <head> this document made on demand, if a script asked for it. */
  headEl: HTMLElement | null = null;
  /** True for a document createDocument() made for XML rather than HTML markup. */
  xmlDocument = true;
  /**
   * The document's encoding: the page reports the one its markup declares (a `<meta charset>`),
   * and a document made in memory or parsed is UTF-8.
   */
  get characterSet(): string {
    return this.defaultView === null ? "UTF-8" : pageCharset;
  }
  get charset(): string { return this.characterSet; }
  get inputEncoding(): string { return this.characterSet; }
  /** The MIME type a browser reports for this kind of document. */
  get contentType(): string {
    if (this.mimeType !== null) return this.mimeType;
    return this.xmlDocument ? "application/xml" : "text/html";
  }
  /** The page's scripts run as one compiled module, so there is no script element in flight. */
  currentScript: Element | null = null;
  /** The MIME type a DOMParser() document was made for; null means this document's own kind. */
  mimeType: string | null = null;
  /** True for a parsed document whose markup had no standards doctype (a quirks document). */
  docQuirks = false;
  /** This document's DOMImplementation, made the first time a script asks. */
  private impl: DOMImplementation | null = null;
  /** The faces the page declares, as document.fonts reports them. */
  readonly fonts = new FontFaceSet();

  constructor() {
    super("#document", "", [], 0, false);
  }

  /** A document's copy: a new document of the same kind (its children come with a deep clone). */
  protected shallowClone(): Node {
    return this.xmlDocument ? new XMLDocument() : new HTMLDocument();
  }

  /**
   * The document's <head>: the one the build compiled, or, for a page built before head's
   * metadata became nodes, one made the first time a script asks and put before the body, as a
   * browser has it. The user-agent stylesheet hides it, so it takes no room.
   */
  get head(): HTMLElement {
    if (this.headEl === null) {
      for (const k of this.documentElement.kids) {
        if (k.isElementNode && k.localName === "head") {
          this.headEl = k as HTMLElement;
          return this.headEl;
        }
      }
      const el = newElementFor("head", "", "", [], 0, false);
      el.dynamic = true;
      el.rulesStale = true;
      this.documentElement.insertBefore(el, this.documentElement.firstChild);
      this.headEl = el;
    }
    return this.headEl;
  }

  /** The sheets of the document's <style> elements, in document order. Adopted sheets are not
   *  part of this list, as in a browser; they apply on top of it. */
  get styleSheets(): CSSStyleSheet[] {
    const out: CSSStyleSheet[] = [];
    collectDocumentSheets(this.documentElement, out);
    return out;
  }

  get adoptedStyleSheets(): CSSStyleSheet[] {
    return ADOPTED.slice();
  }
  set adoptedStyleSheets(sheets: CSSStyleSheet[]) {
    ADOPTED.length = 0;
    for (let i = 0; i < sheets.length; i++) ADOPTED.push(sheets[i]);
    invalidateStyle();
  }

  get activeElement(): Element {
    return focusState.el !== null ? focusState.el : this.body !== null ? this.body : this.documentElement;
  }

  /** Every transition and animation running anywhere in the document. */
  getAnimations(): Animation[] {
    return elementAnimations(this.documentElement, true);
  }

  /** The element the page scrolls with: the root element, as in a standards-mode document. */
  get scrollingElement(): HTMLElement {
    return this.documentElement;
  }

  /** The window the document is shown in, once the window module has loaded. */
  get defaultView(): Window | null {
    return this === (document as Document) ? defaultView : null;
  }

  /**
   * The document's address: the window's for the page itself, and null for a document with no
   * browsing context (one DOMParser or createHTMLDocument made), as a browser reports it.
   */
  get location(): Location | null {
    const view = this.defaultView;
    return view === null ? null : view.location;
  }

  /** The element the window is fullscreen for, or null while it isn't fullscreen. */
  get fullscreenElement(): Element | null {
    return fullscreenEl;
  }
  /** Fullscreen can always be asked for: the app's window is its own. */
  readonly fullscreenEnabled = true;
  /** Leaves fullscreen, as the Escape key and the menu's role do. */
  exitFullscreen(): Promise<void> {
    return exitFullscreenDocument();
  }
  /** The app's window is frontmost whenever it is running: there is no window chrome to leave. */
  hasFocus(): boolean {
    return true;
  }

  /**
   * Runs an editing command, as a browser's `document.execCommand` does: "copy", "cut", "paste",
   * "selectAll" and "insertText" are the commands here. A native app is the user's own program, so
   * the clipboard commands need no permission or user gesture. Returns whether the command did
   * something; `value` is the text "insertText" inserts.
   */
  execCommand(command: string, _showUI: boolean = false, value: string = ""): boolean {
    return runEditCommand(String(command), String(value));
  }

  /** Whether execCommand() knows a command, which for these it always does. */
  queryCommandSupported(command: string): boolean {
    return supportsEditCommand(String(command));
  }

  /** The page is visible unless its window is minimized or hidden by the system. */
  get visibilityState(): DocumentVisibilityState {
    return visibilityState;
  }
  get hidden(): boolean {
    return visibilityState === "hidden";
  }

  /** The document selection, which is always empty here: fields keep their own. */
  /** A new range, at the document's start: the Selection API's factory for one. */
  createRange(): Range {
    return new Range(this.documentElement, 0);
  }

  getSelection(): Selection | null {
    return selection;
  }

  /** The document's direction, which is its root element's `dir` attribute. */
  get dir(): string {
    const root = this.documentElement;
    return root === null ? "" : root.getAttribute("dir") ?? "";
  }
  set dir(value: string) {
    const root = this.documentElement;
    if (root !== null) root.setAttribute("dir", String(value));
  }

  /**
   * The document's title. An HTML document takes the first HTML <title> anywhere in it; an SVG
   * document takes the first SVG <title>; any other XML document has none and cannot be given
   * one. White space folds to single spaces and the edges are trimmed, as a browser reports it.
   */
  get title(): string {
    const t = this.titleElement();
    return t === null ? "" : foldTitle(t.textContent ?? "");
  }
  set title(value: string) {
    const text = String(value);
    const root = this.rootChild();
    if (root === null) return;
    if (this.xmlDocument) {
      const rootNs = root.namespaceURI;
      if (rootNs === "http://www.w3.org/2000/svg" && root.localName === "svg") {
        let t = this.titleElement();
        if (t === null) {
          t = this.createElementNS("http://www.w3.org/2000/svg", "title");
          root.insertBefore(t, root.firstChild);
        }
        t.textContent = text;
        return;
      }
      if (rootNs !== "http://www.w3.org/1999/xhtml") return;
    }
    // An HTML document without a head is left alone, as the spec says.
    const head = this.headElement();
    if (head === null) return;
    let t = this.titleElement();
    if (t === null) {
      t = newElementFor("title", "", "", [], 0, false);
      t.dynamic = true;
      t.rulesStale = true;
      head.appendChild(t);
    }
    t.textContent = text;
    this.titleText = text;
    if (this === (document as Document)) hostSetTitle(text);
  }
  /** The element child of the document (its document element), as the tree stands now. */
  private rootChild(): Element | null {
    for (const k of this.kids) if (k.isElementNode) return k as Element;
    return null;
  }
  /** The document's head element when the tree has one, without making one. */
  private headElement(): Element | null {
    const root = this.rootChild();
    if (root === null) return null;
    for (const k of root.kids) {
      if (k.isElementNode && (k as Element).localName === "head" &&
        (k as Element).namespaceURI === "http://www.w3.org/1999/xhtml") return k as Element;
    }
    return null;
  }
  /** The title element this document's title comes from, if it has one. */
  private titleElement(): Element | null {
    const root = this.rootChild();
    if (root === null) return null;
    const ns = this.xmlDocument
      ? (root.namespaceURI === "http://www.w3.org/2000/svg"
        ? (root.localName === "svg" ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xhtml")
        : root.namespaceURI === "http://www.w3.org/1999/xhtml" ? "http://www.w3.org/1999/xhtml" : null)
      : "http://www.w3.org/1999/xhtml";
    if (ns === null) return null;
    if (ns === "http://www.w3.org/2000/svg") {
      for (const k of root.kids) {
        if (k.isElementNode && (k as Element).localName === "title" && (k as Element).namespaceURI === ns) return k as Element;
      }
      return null;
    }
    let found: Element | null = null;
    const walk = (node: Node): void => {
      for (const k of node.kids) {
        if (found !== null || !k.isElementNode) continue;
        const el = k as Element;
        if (el.localName === "title" && el.namespaceURI === ns) found = el;
        else walk(el);
      }
    };
    walk(root);
    return found;
  }
  getElementById(id: string): HTMLElement | null {
    const el = findById(this.documentElement, id);
    return el === null ? null : el as HTMLElement;
  }
  /** The document's forms, images, links, anchors, embeds (plugins), scripts and applets. */
  get forms(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_FORM, "", true);
  }
  get images(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_IMAGE, "", true);
  }
  get links(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_LINK, "", true);
  }
  get anchors(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_ANCHOR, "", true);
  }
  get embeds(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_EMBED, "", true);
  }
  get plugins(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_EMBED, "", true);
  }
  get scripts(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_SCRIPT, "", true);
  }
  get applets(): HTMLCollection {
    return new HTMLCollection(this.documentElement, COLL_APPLET, "", true);
  }

  /** Every element in the namespace and with the local name ("*" wildcards either). */
  getElementsByTagNameNS(namespace: string, localName: string): Element[] {
    const out: Element[] = [];
    collectByTag(this.documentElement, namespace, localName, out);
    return out;
  }

  /**
   * The topmost element the pointer would reach at a viewport point, or null outside the page. A
   * box the pointer can't reach is left out: see-through with `pointer-events: none`, inert, or
   * not drawn (display: none), so the point reaches what is behind it.
   */
  elementFromPoint(x: number, y: number): Element | null {
    flushLayoutHook();
    if (x < 0 || y < 0 || x >= viewport.w || y >= viewport.h) return null;
    const hits = pointHitsHook(x, y);
    return hits.length > 0 ? hits[0] : null;
  }

  /**
   * Every element the pointer would reach at a viewport point, topmost first, as its own walk. A
   * point outside the viewport reaches nothing, however far a box overflows past it.
   */
  elementsFromPoint(x: number, y: number): Element[] {
    flushLayoutHook();
    if (x < 0 || y < 0 || x >= viewport.w || y >= viewport.h) return [];
    return pointHitsHook(x, y);
  }

  // The tags whose own class the runtime builds (and whose own APIs they carry) name it in the
  // return type, as lib.dom's overloads do; every other tag is a plain HTMLElement.
  createElement(tag: "input"): HTMLInputElement;
  createElement(tag: "canvas"): HTMLCanvasElement;
  createElement(tag: "img"): HTMLImageElement;
  createElement(tag: "template"): HTMLTemplateElement;
  createElement(tag: string): HTMLElement;
  // The implementation names the element type its callers get from the overloads above. Typed
  // rather than untyped so a value crossing to a Node island carries the element's own class
  // (exact-class selection), rather than an untyped dynamic value keyed as HTMLElement.
  createElement(tag: string): HTMLElement {
    // An XML document keeps the name as given; an HTML document lowercases it.
    const name = this.xmlDocument ? tag : tag.toLowerCase();
    // A defined name makes an element of its class here, as a creation context does in a browser.
    const custom = constructCustom(name);
    const el = custom !== null ? custom : newElementFor(name, "", "", [], 0, P.INLINE_TAGS.indexOf(name) >= 0);
    el.owner = this;
    el.dynamic = true;
    el.rulesStale = true;
    return el;
  }
  createElementNS(namespace: string, tag: "input", options?: string | { is?: string }): HTMLInputElement;
  createElementNS(namespace: string, tag: "canvas", options?: string | { is?: string }): HTMLCanvasElement;
  createElementNS(namespace: string, tag: "img", options?: string | { is?: string }): HTMLImageElement;
  createElementNS(namespace: string, tag: "template", options?: string | { is?: string }): HTMLTemplateElement;
  createElementNS(namespace: string, tag: string, options?: string | { is?: string }): HTMLElement;
  createElementNS(namespace: string, tag: string, options?: string | { is?: string }): HTMLElement {
    // Customized built-in elements aren't supported; the option is accepted and ignored, as
    // the DOM API has it, so callers (renderers pass `is`) can call it with three arguments.
    void options;
    // In the HTML namespace a qualified name's prefix is not part of the element's interface:
    // `foo:div` is a div, with `div` for its local name.
    const qualified = String(tag);
    const colon = qualified.indexOf(":");
    const html = namespace === "http://www.w3.org/1999/xhtml";
    const local = html && colon > 0 ? qualified.slice(colon + 1) : qualified;
    const el = this.createElement(local);
    el.namespaceURI = namespace;
    if (colon > 0) {
      el.prefix = qualified.slice(0, colon);
      el.localName = local;
      el.tagName = html ? qualified.toUpperCase() : qualified;
    }
    return el;
  }
  /** A detached attribute node; setAttributeNode puts it on an element. */
  createAttribute(name: any, _legacyValue?: any): Attr {
    const raw = String(name);
    if (raw === "") {
      throw new Error("InvalidCharacterError: Failed to execute 'createAttribute' on 'Document': The name is empty.");
    }
    const a = new Attr(this.xmlDocument ? raw : raw.toLowerCase(), "", null);
    a.ownerDoc = this;
    return a;
  }
  createAttributeNS(namespace: string | null, name: string): Attr {
    const a = this.createAttribute(String(name).split(":").pop() as string);
    return a;
  }

  /** A doctype node (createDocumentType); createDocument can attach one to its document. */
  createDocumentType(name: any, publicId: any = "", systemId: any = ""): DocumentType {
    return this.implementation.createDocumentType(name, publicId, systemId);
  }

  /** A copy of another document's node, owned by this one. */
  importNode<T extends Node>(node: T, deep: boolean = false): T {
    if (node.nodeType === 9) throw new Error("NotSupportedError: Failed to execute 'importNode' on 'Document': The node provided is a document, which may not be imported.");
    const copy = node.cloneNode(deep) as T;
    adoptOwner(copy, this);
    return copy;
  }

  /** Takes a node out of its tree so it belongs to this document, and returns it. */
  adoptNode<T extends Node>(node: T): T {
    if (node.nodeType === 9) throw new Error("NotSupportedError: Failed to execute 'adoptNode' on 'Document': The node provided is a document, which may not be adopted.");
    if (node.parentNode !== null) node.parentNode.removeChild(node);
    adoptOwner(node, this);
    return node;
  }

  /**
   * A CDATA section. An HTML document has none — its text is markup-free already — so this throws
   * on it, as a browser does, and works on a document createDocument() made for XML.
   */
  createCDATASection(data: any): CDATASection {
    if (!this.xmlDocument) {
      throw new Error("NotSupportedError: Failed to execute 'createCDATASection' on 'Document': This operation is not supported for HTML documents.");
    }
    const text = String(data);
    if (text.indexOf("]]>") >= 0) {
      throw new Error("InvalidCharacterError: Failed to execute 'createCDATASection' on 'Document': the data contains ']]>'.");
    }
    const c = new CDATASection(text);
    c.owner = this;
    return c;
  }

  createProcessingInstruction(target: any, data: any): ProcessingInstruction {
    const name = target === null ? "null" : String(target);
    // A processing instruction's target is an XML Name (a colon is allowed), except "xml".
    if (!validXmlName(name) || name.toLowerCase() === "xml") {
      throw new Error(`InvalidCharacterError: Failed to execute 'createProcessingInstruction' on 'Document': '${target}' is not a valid target.`);
    }
    const text = String(data);
    if (text.indexOf("?>") >= 0) {
      throw new Error("InvalidCharacterError: Failed to execute 'createProcessingInstruction' on 'Document': the data contains '?>'.");
    }
    const pi = new ProcessingInstruction(target === null ? "null" : String(target), text);
    pi.owner = this;
    return pi;
  }

  /** The factory for documents and doctypes; a browser's DOMImplementation. */
  get implementation(): DOMImplementation {
    if (this.impl === null) this.impl = new DOMImplementation(this);
    return this.impl;
  }

  /** The root element under the XML name: what DOMParser XML tests reach for. */
  get rootElement(): Element {
    return this.documentElement;
  }

  /** The doctype this document carries, if any. */
  get doctype(): DocumentType | null {
    return documentTypeChild(this);
  }

  /** A document made in memory has no address; the page's own is about:blank too. */
  get URL(): string {
    return "about:blank";
  }
  get baseURI(): string {
    return "about:blank";
  }
  get documentURI(): string {
    return "about:blank";
  }
  /** The document mode the page's doctype selected: quirks or standards. */
  get compatMode(): string {
    if (this.mimeType !== null) return this.docQuirks ? "BackCompat" : "CSS1Compat";
    return isQuirks() ? "BackCompat" : "CSS1Compat";
  }

  /**
   * Writes markup into the page. A page compiled ahead of time has no parser running while its
   * scripts execute, so the markup is appended to the body at the point the script runs; after
   * load, as in a browser, writing first wipes the document (document.open()).
   */
  write(...texts: string[]): void {
    const html = texts.map((t) => String(t)).join("");
    if (this.readyState === "complete") this.open();
    const target: Node = this.body !== null ? this.body : this.documentElement;
    for (const n of parseFragment(html)) target.appendChild(n);
  }

  writeln(...texts: string[]): void {
    this.write(...texts, "\n");
  }

  /** Wipes the document back to an empty html/head/body, as document.open() does. */
  open(): Document {
    const html = this.createElement("html");
    const head = this.createElement("head");
    const body = this.createElement("body");
    html.appendChild(head);
    html.appendChild(body);
    this.kids = [];
    this.kids.push(html);
    html.parentNode = this;
    this.documentElement = html;
    this.headEl = head;
    this.readyState = "loading";
    invalidateStyle();
    return this;
  }

  /** Ends the write stream: the page is complete again. */
  close(): void {
    this.readyState = "complete";
  }

  /**
   * The legacy event constructor by interface name: `createEvent("MouseEvent")` and the older
   * plural spellings a page may still use.
   */
  createEvent(interfaceName: string): Event {
    // The legacy interface table, and nothing else: only the names below are createable, and
    // each makes an event of the interface it names.
    const name = String(interfaceName).toLowerCase();
    if (name === "event" || name === "events" || name === "htmlevents" || name === "svgevents") return new Event("");
    if (name === "beforeunloadevent") return new BeforeUnloadEvent("");
    if (name === "compositionevent") return new CompositionEvent("");
    if (name === "customevent") return new CustomEvent("");
    if (name === "devicemotionevent") return new DeviceMotionEvent("");
    if (name === "deviceorientationevent") return new DeviceOrientationEvent("");
    if (name === "dragevent") return new DragEvent("");
    if (name === "focusevent") return new FocusEvent("");
    if (name === "hashchangeevent") return new HashChangeEvent("");
    if (name === "keyboardevent") return new KeyboardEvent("");
    if (name === "messageevent") return new MessageEvent("");
    if (name === "mouseevent" || name === "mouseevents") return new MouseEvent("");
    if (name === "storageevent") return new StorageEvent("");
    if (name === "textevent") return new TextEvent("");
    if (name === "uievent" || name === "uievents") return new UIEvent("");
    throw new Error(`NotSupportedError: Failed to execute 'createEvent' on 'Document': The provided event type ('${String(interfaceName)}') is invalid.`);
  }

  createTextNode(data: any): Text {
    // Renderers hand a number or any other value here for a `{count}` child, which the DOM
    // converts to a string rather than refusing.
    const t = new Text(String(data));
    t.owner = this;
    t.dynamic = true;
    return t;
  }
  createComment(data: any): Comment {
    const c = new Comment(String(data));
    c.owner = this;
    return c;
  }
  createDocumentFragment(): DocumentFragment {
    const f = new DocumentFragment();
    f.owner = this;
    return f;
  }
  /** A walker over `root`'s subtree, taking only the node types `whatToShow` names and what
   *  `filter` accepts. Every document makes walkers the same way, as a browser's does. */
  createTreeWalker(root: Node, whatToShow: number = NodeFilter.SHOW_ALL,
    filter: NodeFilterLike | NodeFilterObject | null = null): TreeWalker {
    return new TreeWalker(root, whatToShow, filter);
  }
  /** A cursor over `root`'s subtree in document order, taking the types and filter a walker does. */
  createNodeIterator(root: Node, whatToShow: number = NodeFilter.SHOW_ALL,
    filter: NodeFilterLike | NodeFilterObject | null = null): NodeIterator {
    return new NodeIterator(root, whatToShow, filter);
  }
  /** A query from the document searches the whole tree, root element included, and its :scope
   *  is the root element. */
  querySelector<T extends Element = Element>(selector: string): T | null {
    const sels = parseSelectorArg(selector, "querySelector", "Document");
    const root = this.documentElement;
    if (matchesAny(root, sels, root)) return root as unknown as T;
    return firstMatch(root, sels, root) as T | null;
  }
  querySelectorAll<T extends Element = Element>(selector: string): T[] {
    const sels = parseSelectorArg(selector, "querySelectorAll", "Document");
    const out: Element[] = [];
    const root = this.documentElement;
    if (matchesAny(root, sels, root)) out.push(root);
    collectMatches(root, sels, root, out);
    return out as T[];
  }
  /** Every element with this tag name, the root element included when it matches. */
  getElementsByTagName<T extends Element = Element>(name: string): HTMLCollectionOf<T> {
    return new HTMLCollection(this.documentElement, COLL_TAG, name.toLowerCase(), true);
  }
  /** Every element carrying all of the space-separated class names. */
  getElementsByClassName<T extends Element = Element>(names: string): HTMLCollectionOf<T> {
    return new HTMLCollection(this.documentElement, COLL_CLASS, names, true);
  }
  /**
   * Every element whose name attribute is exactly this, as a form's controls carry it. The
   * argument is a DOMString, so null and undefined convert to "null" and "undefined" rather than
   * failing the call, as a browser's WebIDL does.
   */
  getElementsByName<T extends Element = Element>(name: string | null | undefined): HTMLCollectionOf<T> {
    const text = name === null ? "null" : name === undefined ? "undefined" : name;
    return new HTMLCollection(this.documentElement, COLL_NAME, text, true);
  }

  /** The cookies this document holds, as "name=value" pairs joined by "; ". */
  private cookieJar: string[] = [];

  /**
   * `document.cookie`: the cookies this document holds. There is no HTTP origin behind a native
   * page, so the store is one the page itself fills; a document with no window (createHTMLDocument,
   * a parser's document) is cookie-averse, as a file: origin's is, and answers "" to reads while
   * ignoring writes. A cookie whose text holds a NUL has no grammar and is ignored, as a browser
   * ignores it, and an expiry in the past takes the cookie back out.
   */
  get cookie(): string {
    if (this.defaultView === null) return "";
    return this.cookieJar.join("; ");
  }
  set cookie(value: string | null) {
    if (this.defaultView === null) return;
    const text = value === null ? "" : String(value);
    const first = text.split(";")[0];
    if (first.indexOf("\u0000") >= 0) return;
    const eq = first.indexOf("=");
    if (eq < 0) return;
    const name = first.slice(0, eq).trim();
    if (name === "") return;
    const others = this.cookieJar.filter((c) => !c.startsWith(name + "="));
    const expires = /;\s*expires=([^;]+)/i.exec(text);
    if (expires !== null && new Date(expires[1].trim()).getTime() < Date.now()) {
      this.cookieJar = others;
      return;
    }
    this.cookieJar = others;
    this.cookieJar.push(name + "=" + first.slice(eq + 1).trim());
  }
}

/** The element itself and its descendants, in tree order, that carry every named class. */
function collectByClass(el: Node, names: string, out: HTMLElement[]): void {
  const wanted = names.trim().split(/[ \t\n\r\f]+/).filter((n) => n !== "");
  if (el instanceof Element && el.pseudoKind === P.PE_NONE && wanted.length > 0) {
    let all = true;
    for (const n of wanted) if (!el.classList.contains(n)) { all = false; break; }
    if (all) out.push(el as HTMLElement);
  }
  for (const c of el.kids) collectByClass(c, names, out);
}

/** The element itself and its descendants, in tree order, matching namespace and local name. */
function collectByTag(el: Node, namespace: string, localName: string, out: Element[]): void {
  if (el instanceof Element && el.pseudoKind === P.PE_NONE) {
    const ns = namespace === "*" || el.namespaceURI === namespace;
    // HTML tag names match in any case; the parser lowercases them, so are the lookups.
    const name = localName === "*" || el.localName.toLowerCase() === localName.toLowerCase();
    if (ns && name) out.push(el);
  }
  for (const c of el.kids) collectByTag(c, namespace, localName, out);
}

function findById(el: Node, id: string): Element | null {
  if (el.isElementNode && el.pseudoKind === P.PE_NONE && (el as Element).id === id) return el as Element;
  for (const c of el.kids) {
    if (c.pseudoKind !== P.PE_NONE) continue;
    const found = findById(c, id);
    if (found !== null) return found;
  }
  return null;
}

/** A node just put into the tree: parse the <style> elements it holds, or the one it feeds. */
function refreshAdded(node: Node): void {
  if (node.nodeType === 1) {
    if (CUSTOM_DEFS > 0) {
      // A defined tag makes the node an instance of its class before its callbacks run, and the
      // elements that are in the document report themselves connected once the subtree is in.
      upgradeSubtree(node);
    }
    refreshSubtree(node);
    if (CUSTOM_DEFS > 0) connectedSubtree(node);
  } else if (node.nodeType === 3) refreshTextOwner(node);
}

/** The sheets behind the document's <style> elements, in document order. */
function collectDocumentSheets(node: Node, out: CSSStyleSheet[]): void {
  if (node instanceof Element && node.pseudoKind === P.PE_NONE) {
    if (node.localName === "style") refreshSheet(node);
    if (node.sheet !== null) out.push(node.sheet);
  }
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) collectDocumentSheets(c, out);
}

// ---------------------------------------------------------------------------
// Markup: the small HTML parser behind innerHTML, and the serializer behind it

const VOID_ELEMENTS = new Set([
  "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen",
  "link", "meta", "param", "source", "track", "wbr",
]);
/** Elements whose text is not parsed as markup: script and style keep it raw, and the RCDATA
 *  elements decode entities but still read no tags. */
const RAW_TEXT_ELEMENTS = new Set(["script", "style", "xmp", "iframe", "noembed", "noframes"]);
const RCDATA_ELEMENTS = new Set(["title", "textarea"]);

// HTML's implied end tags: these start tags close an open <p>, as do the list-item ones.
const CLOSES_P = new Set([
  "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
  "dd", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
  "h6", "header", "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p", "pre", "section",
  "summary", "table", "ul",
]);
// Elements that bound the scope in which an implied end tag is looked for.
const SCOPE_STOP = new Set(["html", "table", "td", "th", "caption", "button", "marquee", "object", "applet", "template", "svg", "math"]);
const LIST_STOP = new Set(["ul", "ol", "menu"]);

const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", minus: "−", times: "×",
  middot: "·", mdash: "—", ndash: "–", hellip: "…", copy: "©",
  ensp: " ", emsp: " ", thinsp: " ", hairsp: " ",
  newline: "\n", tab: "\t", lrm: "\u200E", rlm: "\u200F", zerowidthspace: "\u200B", nobreak: "\u2060",
  shy: "\u00AD", plusmn: "±", divide: "÷", ne: "≠", le: "≤", ge: "≥",
  frac12: "½", frac14: "¼", frac34: "¾", deg: "°", micro: "µ",
  para: "¶", sect: "§", bullet: "•", lsquo: "‘", rsquo: "’",
  ldquo: "“", rdquo: "”", sbquo: "‚", bdquo: "„", laquo: "«",
  raquo: "»", prime: "′", reg: "®", trade: "™", euro: "€",
  pound: "£", yen: "¥", cent: "¢", curren: "¤", larr: "←",
  rarr: "→", uarr: "↑", darr: "↓", harr: "↔", iquest: "¿", iexcl: "¡",
};

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]+);/gi, (m: string, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    const found = ENTITIES[name.toLowerCase()];
    return found === undefined ? m : found;
  });
}

function escapeText(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    out += c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c;
  }
  return out;
}

function escapeAttr(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    out += c === "&" ? "&amp;" : c === "\"" ? "&quot;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c;
  }
  return out;
}

/** The children of a node as HTML text, skipping the generated boxes that aren't in the tree. */
/** Whether `display` lays the box out inline: its boundaries add no line breaks. */
function inlineDisplay(d: number): boolean {
  return d === P.D_INLINE || d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX || d === P.D_INLINE_TABLE ||
    d === P.D_INLINE_GRID || d === P.D_INLINE_GRID_LANES || d === P.D_CONTENTS;
}

/** `text-transform` as the layout applies it to a text run. */
function transformFor(node: Node, text: string, before = ""): string {
  const t = node.sv[P.P_TEXT_TRANSFORM];
  if (t === P.TT_UPPERCASE) return text.toUpperCase();
  if (t === P.TT_LOWERCASE) return text.toLowerCase();
  if (t === P.TT_CAPITALIZE) return capitalizeText(text, before);
  return text;
}

/** The character a run of rendered text ends on, for the capitalization of the run after it. */
function lastRenderedChar(text: string): string {
  if (text === "") return "";
  const ch = text.slice(-1);
  // The sentinels a preserved space and tab become are spaces for capitalization.
  return ch === "\u0001" || ch === "\u0002" ? " " : ch;
}

/**
 * The character that precedes `node` in the rendered flow of its ancestors, for the
 * capitalization of text inside it: innerText of a span that sits in the middle of a word keeps
 * that letter lower case.
 */
function previousRenderedChar(node: Node): string {
  let n: Node | null = node;
  while (n !== null) {
    let sib = n.previousSibling;
    while (sib !== null) {
      if (sib.pseudoKind === P.PE_NONE && !(sib.isElementNode && sib.sv[P.P_DISPLAY] === P.D_NONE)) {
        const text = sib.isTextNode ? renderedRun(sib, "")
          : sib.isElementNode ? renderedText(sib, "") : "";
        if (text !== "") return lastRenderedChar(text);
      }
      sib = sib.previousSibling;
    }
    const parent: Node | null = n.parentNode;
    if (parent === null || !parent.isElementNode || !inlineDisplay(parent.sv[P.P_DISPLAY])) return "";
    n = parent;
  }
  return "";
}

/** One text run of rendered text, collapsed or kept per its white-space. */
function renderedRun(node: Node, before = ""): string {
  const ws = node.sv[P.P_WHITE_SPACE];
  const text = transformFor(node, node.ownText, before);
  if (ws === P.W_PRE || ws === P.W_PRE_WRAP || ws === P.W_BREAK_SPACES) {
    // Preserved spaces and tabs are content: they pass through the trimming pass as sentinels,
    // so only collapsible white space is squeezed at the edges.
    return text.replace(/\r\n?/g, "\n").split(" ").join("\u0001").split("\t").join("\u0002");
  }
  if (ws === P.W_PRE_LINE) return text.replace(/\r\n|\r|\n/g, "\u0000").replace(/[ \t\f]+/g, " ").replace(/\u0000/g, "\n");
  return text.replace(/[ \t\f\r\n]+/g, " ");
}

/** The rendered text of `el`'s subtree, by the layout rules innerText follows. */
function renderedText(el: Node, before = ""): string {
  // An element that keeps its text as its own (no child nodes) still has rendered text.
  let out = el.kids.length === 0 && el.ownText !== "" ? renderedRun(el, before) : "";
  let blocks = 0;
  let prev: Element | null = null;
  let prevReplaced = false;
  for (const c of el.kids) {
    if (c.pseudoKind !== P.PE_NONE) continue;
    if (c.isTextNode) {
      let run = renderedRun(c, lastRenderedChar(out));
      if (prevReplaced && run.startsWith(" ")) run = "\u0001" + run.slice(1);
      out += run;
      prevReplaced = false;
      continue;
    }
    if (!c.isElementNode) continue;
    const kid = c as Element;
    const d = kid.sv[P.P_DISPLAY];
    if (d === P.D_NONE) continue;
    if (kid.localName === "br") {
      out += "\n";
      continue;
    }
    const inner = inlineDisplay(d) ? renderedText(kid, lastRenderedChar(out)) : renderedText(kid, "");
    if (inlineDisplay(d)) {
      // An inline replaced box (an image, an input) keeps the spaces on both sides of itself
      // from being collapsed together by the trimming pass.
      if (isReplaced(kid)) {
        if (out.endsWith(" ")) out = out.slice(0, out.length - 1) + "\u0001";
        out += inner;
        prevReplaced = true;
        continue;
      }
      out += inner;
      continue;
    }
    // Cells share a row separated by tabs; blocks by a break, or a blank line when the layout
    // puts vertical margin between them (two <p>s, unlike two <pre>s).
    if (d === P.D_TABLE_CELL) {
      if (blocks > 0) out += "\t";
      out += inner;
      blocks++;
      prev = kid;
      continue;
    }
    if (blocks > 0) out += verticalGap(prev, kid) ? "\n\n" : "\n";
    out += inner;
    blocks++;
    prev = kid;
  }
  return out;
}

/** Whether two block boxes sit a blank line apart: either carries vertical margin. */
function verticalGap(a: Element | null, b: Element): boolean {
  if (a === null) return false;
  const mb = a.sv[P.P_MARGIN_BOTTOM];
  const mt = b.sv[P.P_MARGIN_TOP];
  return (a.su[P.P_MARGIN_BOTTOM] !== P.U_AUTO && mb !== 0) || (b.su[P.P_MARGIN_TOP] !== P.U_AUTO && mt !== 0);
}

/** Fuses the first and last text nodes an assignment wrote with text siblings beside them. */
function mergeTextBoundaries(parent: Node, nodes: Node[]): void {
  if (nodes.length === 0) return;
  const first = nodes[0];
  const before = first.previousSibling;
  if (first.isTextNode && before !== null && before.isTextNode) {
    before.textContent = before.ownText + first.ownText;
    first.parentNode = null;
    const at = parent.kids.indexOf(first);
    if (at >= 0) parent.kids.splice(at, 1);
  }
  const last = nodes[nodes.length - 1];
  const after = last.nextSibling;
  if (last.isTextNode && after !== null && after.isTextNode && last.parentNode !== null) {
    last.textContent = last.ownText + after.ownText;
    after.parentNode = null;
    const at = parent.kids.indexOf(after);
    if (at >= 0) parent.kids.splice(at, 1);
  }
}

/** Drops the block boundaries at the element's own edges and squeezes the blank ones between. */
function trimRendered(s: string): string {
  let t = s.replace(/^[ \t\n]+/, "").replace(/[ \t\n]+$/, "");
  t = t.replace(/[ \t]+\n/g, "\n").replace(/\n[ \t]+/g, "\n");
  t = t.replace(/ {2,}/g, " ");
  while (t.indexOf("\n\n\n") >= 0) t = t.replace(/\n\n\n/g, "\n\n");
  return t;
}

/** The nodes an innerText assignment makes: line breaks become <br>, unless white-space keeps
 *  the text as written. */
function innerTextNodes(el: Node, value: string): Node[] {
  // innerText's setter always writes a line break as a <br>, whatever the white-space mode.
  const text = value.replace(/\r\n?/g, "\n");
  const parts = text.split("\n");
  const out: Node[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i > 0) out.push(newElementFor("br", "", "", [], 0, false));
    if (parts[i] !== "") out.push(new Text(parts[i]));
  }
  return out;
}

/**
 * The text node an element's own text stands for in the DOM, or null: the build sometimes keeps
 * an element's text as the element's own rather than as a text child, and every DOM view of the
 * children has to show it as one.
 */
function ownTextChild(node: Node): Node | null {
  // Only an element's content is text it can hand out as a #text child. A text node's data is
  // itself; handing out a child for it would make a walk of childNodes run forever.
  if (node.nodeType !== 1) return null;
  if (node.ownText === "" || node.kids.length > 0) return null;
  if (node.ownTextNode === null) {
    const t = new Text(node.ownText);
    t.parentNode = node;
    node.ownTextNode = t;
  } else if (node.ownTextNode.ownText !== node.ownText) {
    (node.ownTextNode as any).data = node.ownText;
  }
  return node.ownTextNode;
}

function markupOfChildren(node: Node, opts: GetHTMLOptions | null = null): string {
  let s = "";
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) s += markupOf(c, opts);
  // An element whose text the build kept as its own rather than as a text child still has that
  // text as its content, as textContent says.
  if (s === "" && node.ownText !== "") return escapeText(node.ownText);
  return s;
}

/** The shadow root getHTML() writes for an element: the options name it, or it opts in. */
function serializedRoot(el: Element, opts: GetHTMLOptions | null): ShadowRoot | null {
  if (opts === null) return null;
  const root = el.shadowTree();
  if (root === null) return null;
  if (opts.serializableShadowRoots === true && root.serializable) return root;
  const list = opts.shadowRoots;
  if (list !== undefined) for (const r of list) if (r === root) return root;
  return null;
}

/** The `<template shadowrootmode>` a serialized shadow root is written as. */
function shadowTemplateMarkup(root: ShadowRoot, opts: GetHTMLOptions | null): string {
  let attrs = " shadowrootmode=\"" + root.mode + "\"";
  if (root.delegatesFocus) attrs += " shadowrootdelegatesfocus=\"\"";
  if (root.serializable) attrs += " shadowrootserializable=\"\"";
  if (root.slotAssignment === "manual") attrs += " shadowrootslotassignment=\"manual\"";
  if (root.clonable) attrs += " shadowrootclonable=\"\"";
  return "<template" + attrs + ">" + markupOfChildren(root, opts) + "</template>";
}

function markupOf(node: Node, opts: GetHTMLOptions | null = null): string {
  if (node.nodeType === 3) return escapeText(node.ownText);
  if (node.nodeType === 8) return "<!--" + node.ownText + "-->";
  if (node.nodeType === 11) return markupOfChildren(node, opts);
  const el = node as Element;
  const tag = el.localName;
  let s = "<" + tag;
  const id = el.id;
  if (id !== "") s += " id=\"" + escapeAttr(id) + "\"";
  const cls = el.getAttribute("class");
  if (cls !== null) s += " class=\"" + escapeAttr(cls) + "\"";
  const style = el.getAttribute("style");
  if (style !== null) s += " style=\"" + escapeAttr(style) + "\"";
  if (el.hidden) s += " hidden=\"\"";
  for (const entry of el.attrMap) s += " " + entry[0] + "=\"" + escapeAttr(entry[1]) + "\"";
  if (el.nsAttrs !== null) for (const attr of el.nsAttrs.values()) s += " " + attr.name + "=\"" + escapeAttr(attr.value) + "\"";
  s += ">";
  if (VOID_ELEMENTS.has(tag)) return s;
  const shadow = serializedRoot(el, opts);
  if (shadow !== null) s += shadowTemplateMarkup(shadow, opts);
  if (el instanceof HTMLTemplateElement) {
    s += markupOfChildren((el as HTMLTemplateElement).content, opts);
  } else if (RAW_TEXT_ELEMENTS.has(tag)) {
    for (const c of el.kids) if (c.pseudoKind === P.PE_NONE) s += c.ownText;
  } else {
    s += markupOfChildren(el, opts);
  }
  return s + "</" + tag + ">";
}

/** The options getHTML() takes: which shadow roots to serialize with their host. */
export interface GetHTMLOptions {
  serializableShadowRoots?: boolean;
  shadowRoots?: ShadowRoot[];
}

/** The attachShadow init a declarative `<template shadowrootmode>` describes, or null. */
function declarativeInit(template: HTMLTemplateElement): { mode: string; delegatesFocus: boolean; slotAssignment: string; clonable: boolean; serializable: boolean } | null {
  const mode = (template.getAttribute("shadowrootmode") ?? "").toLowerCase();
  if (mode !== "open" && mode !== "closed") return null;
  const assignment = (template.getAttribute("shadowrootslotassignment") ?? "named").toLowerCase();
  return {
    mode,
    delegatesFocus: template.hasAttribute("shadowrootdelegatesfocus"),
    slotAssignment: assignment === "manual" ? "manual" : "named",
    clonable: template.hasAttribute("shadowrootclonable"),
    serializable: template.hasAttribute("shadowrootserializable"),
  };
}

/**
 * Turns a `<template shadowrootmode>` child into its host's shadow root, as HTML parsing does for
 * a page's own markup and for setHTMLUnsafe(). A host that already has a root keeps it, and the
 * template stays a template.
 */
function adoptDeclarative(host: Element, template: HTMLTemplateElement): boolean {
  if (host.shadowTree() !== null) return false;
  const init = declarativeInit(template);
  if (init === null) return false;
  const root = host.attachShadow(init);
  const content = template.content;
  // Text the build kept as the template's own (a template holding only text) belongs to content.
  if (template.ownText !== "") {
    const text: Node = new Text(template.ownText);
    text.parentNode = content;
    content.kids.push(text);
    template.ownText = "";
  }
  for (const c of content.kids.slice()) {
    c.parentNode = root;
    root.kids.push(c);
  }
  content.kids.length = 0;
  const parent = template.parentNode;
  if (parent !== null) {
    const at = parent.kids.indexOf(template);
    if (at >= 0) parent.kids.splice(at, 1);
    template.parentNode = null;
  }
  adoptDeclarativeIn(root);
  return true;
}

/** Converts the declarative shadow roots among a tree's templates, depth first. */
export function adoptDeclarativeIn(node: Node): void {
  for (const kid of node.kids.slice()) {
    if (!(kid instanceof Element)) continue;
    if (kid instanceof HTMLTemplateElement) {
      const parent = kid.parentNode;
      if (parent instanceof Element) adoptDeclarative(parent, kid);
      continue;
    }
    adoptDeclarativeIn(kid);
  }
}

/** Where a parsed element's children go: a template's content, or the element itself. */
function parseTarget(el: Element): Node {
  return el instanceof HTMLTemplateElement ? (el as HTMLTemplateElement).content : el;
}

/** Parses HTML text into detached nodes, as an innerHTML assignment does. */
function parseFragment(html: string): Node[] {
  const root = new DocumentFragment();
  const stack: Element[] = [];
  const top = (): Node => stack.length === 0 ? root : parseTarget(stack[stack.length - 1]);
  // Content that can't live directly in a table is fostered just before it, as HTML parsing does.
  const TABLE_OK = new Set(["caption", "colgroup", "col", "tbody", "thead", "tfoot", "tr", "td", "th",
    "script", "style", "template", "form", "input"]);
  const place = (node: Node): void => {
    const cur = stack.length === 0 ? null : stack[stack.length - 1];
    if (cur !== null && cur.localName === "table") {
      // localName on the node itself: a cast to Element here would copy a text node.
      const isElement = node.isElementNode;
      const allowed = isElement && TABLE_OK.has(node.localName);
      const isText = !isElement && node.ownText.trim() !== "";
      if (!allowed && (isElement || isText)) {
        const parent = cur.parentNode;
        if (parent !== null) {
          parent.insertBefore(node, cur);
          return;
        }
      }
    }
    top().appendChild(node);
  };
  const closeInScope = (tags: string[], extra: Set<string> | null): void => {
    for (let s = stack.length - 1; s >= 0; s--) {
      const t = stack[s].localName;
      if (tags.indexOf(t) >= 0) {
        stack.length = s;
        return;
      }
      if (SCOPE_STOP.has(t) || (extra !== null && extra.has(t))) return;
    }
  };
  const raw = html.toLowerCase();
  let i = 0;
  while (i < html.length) {
    if (html.startsWith("<!--", i)) {
      const end = html.indexOf("-->", i + 4);
      const data = html.slice(i + 4, end < 0 ? html.length : end);
      top().appendChild(new Comment(data));
      i = end < 0 ? html.length : end + 3;
      continue;
    }
    if (html.startsWith("<?", i)) {
      // A processing instruction is a node: `<?target data?>`.
      const end = html.indexOf("?>", i);
      const body = html.slice(i + 2, end < 0 ? html.length : end);
      const sp = body.search(/\s/);
      const target = (sp < 0 ? body : body.slice(0, sp)).trim();
      const data = (sp < 0 ? "" : body.slice(sp + 1).replace(/^\s+/, "")).split("\u0000").join("\ufffd");
      if (target !== "" && target.toLowerCase() !== "xml") top().appendChild(new ProcessingInstruction(target, data));
      i = end < 0 ? html.length : end + 2;
      continue;
    }
    if (html.startsWith("<!", i)) {
      // A doctype has no node in this model.
      const end = html.indexOf(">", i);
      i = end < 0 ? html.length : end + 1;
      continue;
    }
    if (html.startsWith("</", i)) {
      const end = html.indexOf(">", i);
      const tag = html.slice(i + 2, end < 0 ? html.length : end).trim().toLowerCase();
      for (let s = stack.length - 1; s >= 0; s--) {
        if (stack[s].localName === tag) {
          stack.length = s;
          break;
        }
      }
      i = end < 0 ? html.length : end + 1;
      continue;
    }
    if (html[i] === "<" && /[a-zA-Z]/.test(html[i + 1] ?? "")) {
      let j = i + 1;
      while (j < html.length && /[^\s/>]/.test(html[j])) j++;
      const tag = html.slice(i + 1, j).toLowerCase();
      const attrs: string[] = [];
      const values: string[] = [];
      let selfClosing = false;
      while (j < html.length) {
        while (/\s/.test(html[j])) j++;
        if (html[j] === ">") { j++; break; }
        if (html.startsWith("/>", j)) { selfClosing = true; j += 2; break; }
        let k = j;
        while (k < html.length && /[^\s=/>]/.test(html[k])) k++;
        const name = html.slice(j, k).toLowerCase();
        j = k;
        while (/\s/.test(html[j])) j++;
        let value = "";
        if (html[j] === "=") {
          j++;
          while (/\s/.test(html[j])) j++;
          const q = html[j];
          if (q === "\"" || q === "'") {
            const end = html.indexOf(q, j + 1);
            value = html.slice(j + 1, end < 0 ? html.length : end);
            j = end < 0 ? html.length : end + 1;
          } else {
            k = j;
            while (k < html.length && /[^\s>]/.test(html[k])) k++;
            value = html.slice(j, k);
            j = k;
          }
        }
        if (name !== "") {
          attrs.push(name);
          values.push(decodeEntities(value));
        } else {
          j++;
        }
      }
      if (CLOSES_P.has(tag)) closeInScope(["p"], null);
      if (/^h[1-6]$/.test(tag)) closeInScope(["h1", "h2", "h3", "h4", "h5", "h6"], null);
      if (tag === "td" || tag === "th") closeInScope(["td", "th"], null);
      if (tag === "tr") closeInScope(["tr", "td", "th"], null);
      if (tag === "li") closeInScope(["li"], LIST_STOP);
      else if (tag === "dt" || tag === "dd") closeInScope(["dt", "dd"], LIST_STOP);
      else if (tag === "option") closeInScope(["option"], null);
      else if (tag === "optgroup") closeInScope(["option", "optgroup"], null);
      const el = document.createElement(tag);
      const parent = stack.length === 0 ? null : stack[stack.length - 1];
      // An <svg> enters the SVG namespace, and so does its subtree — except inside foreignObject,
      // whose children are HTML again. Everything else keeps its parent's namespace.
      const SVG_NS = "http://www.w3.org/2000/svg";
      const MATHML_NS = "http://www.w3.org/1998/Math/MathML";
      if (tag === "svg") el.namespaceURI = SVG_NS;
      else if (tag === "math") el.namespaceURI = MATHML_NS;
      else if (parent !== null && parent.namespaceURI === SVG_NS && parent.localName !== "foreignObject") {
        el.namespaceURI = SVG_NS;
      } else if (parent !== null && parent.namespaceURI === MATHML_NS && parent.localName !== "annotation-xml") {
        el.namespaceURI = MATHML_NS;
      } else if (parent !== null) el.namespaceURI = parent.namespaceURI;
      if (tag === "foreignObject" && parent !== null) el.namespaceURI = parent.namespaceURI;
      for (let a = 0; a < attrs.length; a++) setParsedAttribute(el, attrs[a], values[a]);
      place(el);
      i = j;
      if (tag === "plaintext") {
        // Everything after it is its text, to the end of the input.
        if (html.length > i) el.appendChild(new Text(html.slice(i)));
        i = html.length;
      } else if (RAW_TEXT_ELEMENTS.has(tag) || RCDATA_ELEMENTS.has(tag)) {
        const close = raw.indexOf("</" + tag, i);
        const end = close < 0 ? html.length : close;
        if (end > i) {
          const data = html.slice(i, end);
          el.appendChild(new Text(RCDATA_ELEMENTS.has(tag) ? decodeEntities(data) : data));
        }
        const gt = close < 0 ? -1 : html.indexOf(">", close);
        i = gt < 0 ? html.length : gt + 1;
      } else if (!selfClosing && !VOID_ELEMENTS.has(tag)) {
        stack.push(el);
      }
      continue;
    }
    let end = html.indexOf("<", i + 1);
    if (end < 0) end = html.length;
    if (end > i) place(new Text(decodeEntities(html.slice(i, end))));
    i = end;
  }
  const nodes = root.kids.slice();
  root.kids = [];
  for (const n of nodes) n.parentNode = null;
  return nodes;
}

/** The namespace of an element node, or null for a node that isn't one. */
export function elementNamespace(el: Node): string | null {
  return el.isElementNode ? (el as Element).namespaceURI : null;
}

/** Sets an element node's namespace; mounting inline SVG gives its subtree the SVG namespace. */
export function setElementNamespace(el: Node, uri: string): void {
  if (el.isElementNode) (el as Element).namespaceURI = uri;
}

/** The XML document interface; createDocument() makes one (its constructor is open to scripts). */
export class XMLDocument extends Document {
  get [Symbol.toStringTag](): string { return "XMLDocument"; }
  constructor() {
    super();
    this.xmlDocument = true;
  }
}

/** The HTML document interface: the page's own document and createHTMLDocument()'s. */
export class HTMLDocument extends Document {
  get [Symbol.toStringTag](): string { return "HTMLDocument"; }
  constructor() {
    super();
    this.xmlDocument = false;
  }
}

/**
 * A static range: the two boundary points a script names, with no live tree behind it. The
 * boundary containers must be nodes (a doctype or an attribute is an InvalidNodeTypeError), and
 * every field is required (a missing one is the TypeError the dictionary conversion throws).
 */
export class StaticRange extends AbstractRange {
  get [Symbol.toStringTag](): string { return "StaticRange"; }
  readonly startContainer: Node;
  readonly startOffset: number;
  readonly endContainer: Node;
  readonly endOffset: number;

  constructor(init: any = undefined) {
    super("abstract-range");
    if (init === null || init === undefined) throw new TypeError("Failed to construct 'StaticRange': 1 argument required, but only 0 present.");
    const sc = init.startContainer;
    const so = init.startOffset;
    const ec = init.endContainer;
    const eo = init.endOffset;
    if (sc === null || sc === undefined || ec === null || ec === undefined ||
      so === null || so === undefined || eo === null || eo === undefined) {
      throw new TypeError("Failed to construct 'StaticRange': required member is undefined.");
    }
    // A boundary container is any node but a doctype or an attribute; an Attr isn't a Node here,
    // so it shows up as a missing nodeType.
    const scType = typeof sc.nodeType === "number" ? sc.nodeType : -1;
    const ecType = typeof ec.nodeType === "number" ? ec.nodeType : -1;
    const scBad = scType < 0 || scType === 10 || scType === 2;
    const ecBad = ecType < 0 || ecType === 10 || ecType === 2;
    if (scBad || ecBad) {
      throw new Error("InvalidNodeTypeError: Failed to construct 'StaticRange': the boundary node type is invalid.");
    }
    this.startContainer = sc;
    this.startOffset = Number(so);
    this.endContainer = ec;
    this.endOffset = Number(eo);
  }

  get collapsed(): boolean {
    return this.startContainer === this.endContainer && this.startOffset === this.endOffset;
  }
}

// ---------------------------------------------------------------------------
// DOMParser and XMLSerializer

/**
 * DOMParser: parses markup into a document of its own. `text/html` builds an HTMLDocument as a
 * browser's parser would (a standards doctype or none decides its mode); the XML types build an
 * XMLDocument with namespaces from `xmlns`, and malformed XML gives the parsererror document a
 * browser produces instead of a document tree.
 */
export class DOMParser {
  get [Symbol.toStringTag](): string { return "DOMParser"; }
  parseFromString(text: any, type: any): Document {
    const mime = String(type).toLowerCase();
    const src = String(text);
    if (mime === "text/html") return htmlFromMarkup(src);
    if (mime !== "application/xml" && mime !== "text/xml" && mime !== "image/svg+xml" && mime !== "application/xhtml+xml") {
      throw new TypeError("Failed to execute 'parseFromString' on 'DOMParser': The provided value '" + String(type) + "' is not a valid enum value of type SupportedType.");
    }
    // The parsed document is a Document, not the XMLDocument class createDocument() makes:
    // `doc instanceof XMLDocument` is false for a DOMParser result in a browser.
    const doc = new Document();
    doc.mimeType = mime;
    doc.readyState = "complete";
    if (!xmlFromMarkup(doc, src)) return xmlParserError(mime);
    // The parsed tree's root is the document element; a fresh Document() starts out with an
    // html element placeholder that a parsed XML document doesn't have.
    for (const k of doc.kids) {
      if (k.isElementNode && k.pseudoKind === P.PE_NONE) {
        doc.documentElement = k as HTMLElement;
        break;
      }
    }
    return doc;
  }
}

/** The document a browser gives for malformed XML: one parsererror element, in its namespace. */
function xmlParserError(mime: string): Document {
  const doc = new Document();
  doc.mimeType = mime;
  doc.readyState = "complete";
  const err = newElementFor("parsererror", "", "", [], 0, false);
  // XML keeps names as written: the error element's name is lowercase, not an HTML tag's upper.
  err.localName = "parsererror";
  err.tagName = "parsererror";
  err.nodeName = "parsererror";
  err.owner = doc;
  err.namespaceURI = "http://www.mozilla.org/newlayout/xml/parsererror.xml";
  err.textContent = "This page contains the following errors:\n\nerror on line 1 at column 1: not well-formed\n";
  doc.documentElement = err;
  doc.kids.push(err);
  err.parentNode = doc;
  return doc;
}

/** Parses `text/html` markup into a document, with html, head and body as the parser makes them. */
function htmlFromMarkup(src: string): Document {
  const doc = new HTMLDocument();
  doc.mimeType = "text/html";
  doc.readyState = "complete";
  doc.docQuirks = !/^\s*<!doctype\s+html/i.test(src);
  const nodes = parseFragment(src);
  let html: HTMLElement | null = null;
  for (const n of nodes) if (n instanceof Element && n.localName === "html") html = n as HTMLElement;
  let head: HTMLElement | null = null;
  let body: HTMLElement | null = null;
  if (html === null) {
    html = newElementFor("html", "", "", [], 0, false);
    head = newElementFor("head", "", "", [], 0, false);
    body = newElementFor("body", "", "", [], 0, false);
    html.appendChild(head);
    html.appendChild(body);
    for (const n of nodes) body.appendChild(n);
  } else {
    for (const k of html.kids) {
      if (!(k instanceof HTMLElement)) continue;
      if (k.localName === "head") head = k;
      else if (k.localName === "body") body = k;
    }
    if (body === null) {
      body = newElementFor("body", "", "", [], 0, false);
      html.appendChild(body);
    }
  }
  html.owner = doc;
  if (head !== null) head.owner = doc;
  body.owner = doc;
  doc.documentElement = html;
  doc.body = body;
  doc.headEl = head;
  doc.kids.push(html);
  html.parentNode = doc;
  return doc;
}

/**
 * Parses XML markup into `doc`. Returns false when the markup isn't well-formed (an unclosed or
 * mismatched tag, or a stray end tag), which the caller turns into a parsererror document.
 */
function xmlFromMarkup(doc: Document, src: string): boolean {
  const stack: Node[] = [doc];
  /** Entities the document's internal subset declares (`<!ENTITY name "value">`). */
  const entities = new Map<string, string>();
  const scopes: Map<string, string>[] = [new Map([["xml", "http://www.w3.org/XML/1998/namespace"]])];
  const top = (): Node => stack[stack.length - 1];
  const scope = (): Map<string, string> => scopes[scopes.length - 1];
  let i = 0;
  while (i < src.length) {
    if (src.startsWith("<!--", i)) {
      const end = src.indexOf("-->", i + 4);
      if (end < 0) return false;
      top().appendChild(new Comment(src.slice(i + 4, end)));
      i = end + 3;
      continue;
    }
    if (src.startsWith("<![CDATA[", i)) {
      const end = src.indexOf("]]>", i + 9);
      if (end < 0) return false;
      top().appendChild(new CDATASection(xmlSanitize(src.slice(i + 9, end))));
      i = end + 3;
      continue;
    }
    if (src.startsWith("<?", i)) {
      const end = src.indexOf("?>", i);
      if (end < 0) return false;
      const body = src.slice(i + 2, end);
      const sp = body.search(/\s/);
      const target = (sp < 0 ? body : body.slice(0, sp)).trim();
      const data = sp < 0 ? "" : body.slice(sp + 1).replace(/^\s+/, "");
      if (target !== "" && target.toLowerCase() !== "xml") top().appendChild(new ProcessingInstruction(target, data));
      i = end + 2;
      continue;
    }
    if (src.startsWith("<!DOCTYPE", i) || src.startsWith("<!doctype", i)) {
      // `<!DOCTYPE name PUBLIC "publicId" "systemId">`, or with an internal subset in brackets.
      let end = i + 9;
      let depth = 0;
      while (end < src.length) {
        const c = src[end];
        if (c === "[") depth++;
        else if (c === "]") depth--;
        else if (c === ">" && depth <= 0) break;
        end++;
      }
      if (end >= src.length) return false;
      const body = src.slice(i + 9, end).trim();
      const nm = /^([^\s\[]+)/.exec(body);
      if (nm !== null) {
        // Only the declaration before an internal subset names the identifiers; quoted strings
        // inside the subset are entity values, not an id.
        const header = body.indexOf("[") >= 0 ? body.slice(0, body.indexOf("[")) : body;
        const rest = header.slice(nm[1].length);
        const ids = [...rest.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
        const isPublic = /^\s*PUBLIC/i.test(rest);
        const isSystem = /^\s*SYSTEM/i.test(rest);
        // PUBLIC needs the public id and the system id; SYSTEM needs exactly one literal.
        if (isPublic && ids.length < 1) return false;
        const sys = isPublic ? (ids.length > 1 ? ids[1] : null) : ids.length > 0 ? ids[0] : null;
        if (isPublic && sys === null) return false;
        if (isSystem && ids.length !== 1) return false;
        // An internal subset may declare general entities; they are expanded as text is read.
        const subsetOpen = body.indexOf("[");
        const subsetClose = body.lastIndexOf("]");
        if (subsetOpen >= 0 && subsetClose > subsetOpen) {
          const subset = body.slice(subsetOpen + 1, subsetClose);
          const ere = /<!ENTITY\s+([A-Za-z_][\w.-]*)\s+"([^"]*)"/g;
          let em: RegExpExecArray | null;
          while ((em = ere.exec(subset)) !== null) entities.set(em[1], em[2]);
        }
        const dt = new DocumentType(nm[1], isPublic ? ids[0] : "", sys === null ? "" : sys);
        dt.owner = doc;
        doc.appendChild(dt);
      }
      i = end + 1;
      continue;
    }
    if (src.startsWith("<!", i)) {
      const end = src.indexOf(">", i);
      if (end < 0) return false;
      i = end + 1;
      continue;
    }
    if (src.startsWith("</", i)) {
      const end = src.indexOf(">", i);
      if (end < 0) return false;
      const rawName = src.slice(i + 2, end);
      const name = rawName.trim();
      // An end tag is `</name>` exactly: spaces inside the name are a parse error in XML.
      if (rawName !== name || !validXmlName(localOf(name)) || (name.indexOf(":") > 0 && !validXmlName(name.slice(0, name.indexOf(":"))))) return false;
      if (stack.length <= 1) return false;
      const open = top();
      if (open.nodeType !== 1 || (open as Element).localName !== localOf(name) || stack.length < 2) return false;
      stack.pop();
      scopes.pop();
      i = end + 1;
      continue;
    }
    if (src[i] === "<") {
      const end = tagEnd(src, i);
      if (end < 0) return false;
      const raw = src.slice(i + 1, end);
      const selfClosing = raw.endsWith("/");
      const body = selfClosing ? raw.slice(0, raw.length - 1) : raw;
      const nameEnd = body.search(/\s/);
      const qname = (nameEnd < 0 ? body : body.slice(0, nameEnd)).trim();
      if (qname === "") return false;
      const el = doc.createElement(qname);
      // XML names keep their case, and an element's tagName is its qualified name as written
      // (an HTML element uppercases both, which is why createElement made one).
      el.localName = localOf(qname);
      el.tagName = qname;
      el.nodeName = qname;
      const attrs = nameEnd < 0 ? "" : body.slice(nameEnd);
      const scopeMap = new Map<string, string>();
      for (const [k, v] of scope()) scopeMap.set(k, v);
      // A tag's own xmlns attributes may come after the names they qualify, so they land first.
      if (!setXmlAttrs(el, attrs, scopeMap)) return false;
      const colonAt = qname.indexOf(":");
      const prefix = colonAt > 0 ? qname.slice(0, colonAt) : "";
      if (!validXmlName(colonAt > 0 ? qname.slice(colonAt + 1) : qname) || (colonAt === 0)) return false;
      if (prefix !== "" && (!validXmlName(prefix) || !scopeMap.has(prefix))) return false;
      el.namespaceURI = scopeMap.get(prefix) ?? null;
      el.owner = doc;
      top().appendChild(el);
      if (!selfClosing) {
        stack.push(el);
        scopes.push(scopeMap);
      }
      i = end + 1;
      continue;
    }
    const next = src.indexOf("<", i);
    const stop = next < 0 ? src.length : next;
    const raw = src.slice(i, stop);
    let expanded = raw;
    if (entities.size > 0) for (let round = 0; round < 2; round++) {
      for (const [k, v] of entities) expanded = expanded.split("&" + k + ";").join(v);
    }
    const text = xmlSanitize(decodeEntities(expanded));
    if (text !== "") {
      // Whitespace between the document's nodes is not content; other text there isn't XML.
      if (top().nodeType === 9) {
        if (text.trim() !== "") return false;
      } else top().appendChild(new Text(text));
    }
    i = stop;
  }
  return stack.length === 1;
}

/** The local name of a qualified name. */
function localOf(qname: string): string {
  const colon = qname.indexOf(":");
  return colon < 0 ? qname : qname.slice(colon + 1);
}

/** The `>` that ends a start tag at `i`, ignoring quoted attribute values; -1 if unterminated. */
function tagEnd(src: string, i: number): number {
  let quote = "";
  for (let j = i + 1; j < src.length; j++) {
    const c = src[j];
    if (quote !== "") {
      if (c === quote) quote = "";
      continue;
    }
    if (c === '"' || c === "'") quote = c;
    else if (c === ">") return j;
  }
  return -1;
}

/** An XML name, in the ASCII subset the tests use (a prefixed name is checked part by part). */
function validXmlName(name: string): boolean {
  if (name === "") return false;
  let i = 0;
  const first = name.codePointAt(0)!;
  if (!isNameStartChar(first)) return false;
  i += first > 0xffff ? 2 : 1;
  while (i < name.length) {
    const c = name.codePointAt(i)!;
    if (!isNameChar(c)) return false;
    i += c > 0xffff ? 2 : 1;
  }
  return true;
}

/** XML's NameStartChar production. */
function isNameStartChar(c: number): boolean {
  return c === 0x3a || c === 0x5f || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) ||
    (c >= 0xc0 && c <= 0xd6) || (c >= 0xd8 && c <= 0xf6) || (c >= 0xf8 && c <= 0x2ff) ||
    (c >= 0x370 && c <= 0x37d) || (c >= 0x37f && c <= 0x1fff) || (c >= 0x200c && c <= 0x200d) ||
    (c >= 0x2070 && c <= 0x218f) || (c >= 0x2c00 && c <= 0x2fef) || (c >= 0x3001 && c <= 0xd7ff) ||
    (c >= 0xf900 && c <= 0xfdcf) || (c >= 0xfdf0 && c <= 0xfffd) || (c >= 0x10000 && c <= 0xeffff);
}

/** XML's NameChar production: NameStartChar, a digit, or the punctuation a name may contain. */
function isNameChar(c: number): boolean {
  return isNameStartChar(c) || c === 0x2d || c === 0x2e || (c >= 0x30 && c <= 0x39) || c === 0xb7 ||
    (c >= 0x300 && c <= 0x36f) || (c >= 0x203f && c <= 0x2040);
}

/** A string with lone surrogates replaced by U+FFFD, as a browser's XML parser leaves them. */
function xmlSanitize(text: string): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
      if (next >= 0xdc00 && next <= 0xdfff) {
        out += text[i] + text[i + 1];
        i++;
      } else out += "\ufffd";
    } else if (c >= 0xdc00 && c <= 0xdfff) out += "\ufffd";
    else out += text[i];
  }
  return out;
}

/** The (name, value) pairs of a start tag, in order; null when the attributes aren't well-formed. */
function xmlAttrPairs(attrs: string): string[][] | null {
  const re = /([^\s=]+)\s*=\s*("([^"]*)"|'([^']*)')/g;
  const out: string[][] = [];
  let m: RegExpExecArray | null;
  let last = 0;
  while ((m = re.exec(attrs)) !== null) {
    if (attrs.slice(last, m.index).trim() !== "") return null;
    out.push([m[1], m[3] === undefined ? m[4] : m[3]]);
    last = m.index + m[0].length;
  }
  if (attrs.slice(last).trim() !== "") return null;
  return out;
}

/**
 * Sets one attribute a start tag carries. On a foreign element the names HTML gives an
 * implied namespace (xlink:, xml:, xmlns) take that namespace, as the HTML parser's adjust
 * foreign attributes step does; on an HTML element every name is a null-namespace attribute.
 */
function setParsedAttribute(el: Element, name: string, value: string): void {
  const ns = el.namespaceURI;
  if (ns === "http://www.w3.org/2000/svg" || ns === "http://www.w3.org/1998/Math/MathML") {
    if (name.startsWith("xlink:")) {
      el.setAttributeNS("http://www.w3.org/1999/xlink", name, value);
      return;
    }
    if (name.startsWith("xml:")) {
      el.setAttributeNS("http://www.w3.org/XML/1998/namespace", name, value);
      return;
    }
    if (name === "xmlns" || name.startsWith("xmlns:")) {
      el.setAttributeNS("http://www.w3.org/2000/xmlns/", name, value);
      return;
    }
  }
  el.setAttribute(name, value);
}

/** Sets a start tag's attributes, declaring namespaces into `scopeMap` (xmlns, xmlns:p). */
function setXmlAttrs(el: Element, attrs: string, scopeMap: Map<string, string>): boolean {
  const pairs = xmlAttrPairs(attrs);
  if (pairs === null) return false;
  // Declarations first: a prefix may be declared after the attribute that uses it in the tag.
  for (const [name, raw] of pairs) {
    if (name === "xmlns") scopeMap.set("", xmlSanitize(decodeEntities(raw)));
    else if (name.startsWith("xmlns:")) {
      const p = name.slice(6);
      if (p === "" || p === "xmlns" || !validXmlName(p)) return false;
      scopeMap.set(p, xmlSanitize(decodeEntities(raw)));
    }
  }
  for (const [name, raw] of pairs) {
    if (name === "xmlns" || name.startsWith("xmlns:")) {
      el.setAttribute(name, xmlSanitize(decodeEntities(raw)));
      continue;
    }
    const colon = name.indexOf(":");
    const prefix = colon > 0 ? name.slice(0, colon) : "";
    if (colon === 0 || !validXmlName(colon > 0 ? name.slice(colon + 1) : name) || (prefix !== "" && !validXmlName(prefix))) return false;
    const value = xmlSanitize(decodeEntities(raw));
    if (prefix !== "") {
      if (!scopeMap.has(prefix)) return false;
      el.setAttributeNS(scopeMap.get(prefix) ?? null, name, value);
    } else el.setAttribute(name, value);
  }
  return true;
}

/** XMLSerializer: the XML text of a node, as browsers' serializer writes it. */
export class XMLSerializer {
  get [Symbol.toStringTag](): string { return "XMLSerializer"; }
  serializeToString(node: Node): string {
    return xmlMarkup(node);
  }
}

function xmlMarkup(node: Node): string {
  const t = node.nodeType;
  if (t === 3) return escapeText(node.ownText);
  if (t === 4) return "<![CDATA[" + node.ownText + "]]>";
  if (t === 8) return "<!--" + node.ownText + "-->";
  if (t === 7) return "<?" + (node as ProcessingInstruction).target + (node.ownText === "" ? "" : " " + node.ownText) + "?>";
  if (t === 10) return "<!DOCTYPE " + (node as DocumentType).name + ">";
  if (t === 9 || t === 11) {
    let s = "";
    for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) s += xmlMarkup(c);
    return s;
  }
  const el = node as Element;
  let s = "<" + el.localName;
  for (const name of el.attributeNames()) {
    const v = el.getAttribute(name);
    s += " " + name + "=\"" + escapeAttr(v === null ? "" : v) + "\"";
  }
  if (el.kids.length === 0) return s + "/>";
  s += ">";
  for (const c of el.kids) if (c.pseudoKind === P.PE_NONE) s += xmlMarkup(c);
  return s + "</" + el.localName + ">";
}

// Filled in by mount() from the compiled node tables before user code runs.
export const document: Document = new HTMLDocument();
