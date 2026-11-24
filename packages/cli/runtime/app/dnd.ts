// HTML drag and drop, and a drop of files from outside the app.
//
// A press on something draggable that then moves starts a drag: the source hears dragstart, the
// element under the pointer hears dragenter and dragover, a release over one that takes the drag
// fires drop, and the source hears dragend whatever happened. The payload a drag carries is a
// DataTransfer, the same object a drop's handler reads and writes. The host's own drag (files
// dragged in from the Finder) arrives as one drop with files, which takes the same path.

import {
  DataTransfer, DragEvent, Element, File, HTMLAnchorElement, HTMLElement, HTMLImageElement, Node, document, dispatch, trusted,
} from "../dom.ts";
import { MOD_META, MOD_SHIFT, MOD_ALT, MOD_CTRL, hostDropFileCount, hostDropFileName, hostDropFilePath, hostFileSize } from "../host.ts";

/** How far the pointer moves with the button down before the press becomes a drag, in CSS px. */
const DRAG_THRESHOLD = 4;

/** The drag in progress, if there is one. */
const drag = {
  /** The press that may become a drag: what it was on, and where it started. */
  candidate: null as Element | null,
  startX: 0,
  startY: 0,
  active: false,
  /** What the drag was started from: the source element. */
  source: null as Element | null,
  dataTransfer: null as DataTransfer | null,
  /** The element under the pointer, which a drop would land on. */
  target: null as Node | null,
  /** Whether the last dragover over `target` was taken, so a release there drops. */
  accepted: false,
};

/** The nearest element the press would drag: the element itself or an ancestor that drags. */
function dragSourceAt(target: Node | null): Element | null {
  let el: Node | null = target;
  while (el !== null && !el.isElementNode) el = el.parentNode;
  while (el !== null) {
    if (el instanceof HTMLElement && el.draggable) return el;
    el = el.parentElement;
  }
  return null;
}

/** The data a link or an image drags with, when its dragstart handler doesn't set its own. */
function defaultDragData(el: Element, dt: DataTransfer): void {
  const url = el instanceof HTMLImageElement ? el.getAttribute("src") ?? ""
    : el instanceof HTMLAnchorElement ? el.getAttribute("href") ?? "" : "";
  if (url === "") return;
  dt.setData("text/uri-list", url);
  dt.setData("text/plain", url);
}

/** The effect a drag with this `effectAllowed` has under these modifier keys. */
function effectFor(allowed: string, mods: number): string {
  const alt = (mods & MOD_ALT) !== 0;
  if (allowed === "uninitialized" || allowed === "all") return "copy";
  if (allowed === "copyMove") return alt ? "copy" : "move";
  if (allowed === "linkMove") return alt ? "link" : "move";
  if (allowed === "copyLink") return alt ? "link" : "copy";
  return allowed;
}

function dragEvent(type: string, dt: DataTransfer, x: number, y: number, mods: number, cancelable: boolean): DragEvent {
  return trusted(new DragEvent(type, {
    bubbles: true, cancelable, composed: true, clientX: x, clientY: y,
    metaKey: (mods & MOD_META) !== 0, shiftKey: (mods & MOD_SHIFT) !== 0,
    altKey: (mods & MOD_ALT) !== 0, ctrlKey: (mods & MOD_CTRL) !== 0,
    dataTransfer: dt,
  }));
}

/**
 * A press landed at (x, y): an element that drags is remembered, and the press becomes a drag
 * once the pointer has moved far enough.
 */
export function noteDragPress(target: Node | null, x: number, y: number): void {
  drag.candidate = target === null ? null : dragSourceAt(target);
  drag.startX = x;
  drag.startY = y;
}

/** A press that ended without moving forgets what it was on. */
export function endDragPress(): void {
  if (!drag.active) drag.candidate = null;
}

/**
 * The pointer moved with the button down. Starts the drag when the press was on something
 * draggable and the pointer has moved far enough, then sends drag and the target's dragenter,
 * dragleave and dragover. `target` is the element under the pointer, as the pointer's own hit
 * test found it — the drag reuses it so it and a click agree on what is under the point.
 * Returns whether the drag took the move.
 */
export function dragMove(x: number, y: number, target: Node | null, mods: number): boolean {
  if (!drag.active) {
    const source = drag.candidate;
    if (source === null) return false;
    const dx = x - drag.startX, dy = y - drag.startY;
    if (dx * dx + dy * dy < DRAG_THRESHOLD * DRAG_THRESHOLD) return false;
    const dt = new DataTransfer();
    defaultDragData(source, dt);
    const start = dragEvent("dragstart", dt, x, y, mods, true);
    dispatch(start, source);
    // A cancelled dragstart keeps what the press would have done, as a browser falls back to it.
    if (start.defaultPrevented) {
      drag.candidate = null;
      return false;
    }
    drag.candidate = null;
    drag.active = true;
    drag.source = source;
    drag.dataTransfer = dt;
    drag.target = null;
    drag.accepted = false;
  }
  const dt = drag.dataTransfer as DataTransfer;
  const source = drag.source as Element;
  dispatch(dragEvent("drag", dt, x, y, mods, true), source);
  // A new element under the pointer leaves the old one and enters the new one.
  if (target !== drag.target) {
    if (drag.target !== null) dispatch(dragEvent("dragleave", dt, x, y, mods, false), drag.target);
    drag.target = target;
    if (target !== null) enterAt(target, dt, x, y, mods);
  }
  if (target !== null) drag.accepted = overAt(target, dt, x, y, mods);
  return true;
}

/** The new element under the pointer hears dragenter, which may take the drag on its own. */
function enterAt(target: Node, dt: DataTransfer, x: number, y: number, mods: number): void {
  const enter = dragEvent("dragenter", dt, x, y, mods, true);
  dispatch(enter, target);
  dt.dropEffect = enter.defaultPrevented ? effectFor(dt.effectAllowed, mods) : "none";
}

/**
 * The element under the pointer hears dragover, which a handler cancels to take the drop. The
 * effect a drop here would have comes from what the drag allows until a handler sets one.
 */
function overAt(target: Node, dt: DataTransfer, x: number, y: number, mods: number): boolean {
  dt.dropEffect = effectFor(dt.effectAllowed, mods);
  const over = dragEvent("dragover", dt, x, y, mods, true);
  dispatch(over, target);
  if (!over.defaultPrevented) dt.dropEffect = "none";
  return over.defaultPrevented && dt.dropEffect !== "none";
}

/**
 * The button lifted with a drag in progress: a target that took the drag hears drop, and the
 * source hears dragend whatever happened. Returns whether the release belonged to the drag, which
 * leaves the click unsent as a browser does.
 */
export function dragUp(x: number, y: number, target: Node | null, mods: number): boolean {
  if (!drag.active) return false;
  const dt = drag.dataTransfer as DataTransfer;
  const source = drag.source as Element;
  // A release on an element the pointer never dragged over still enters and moves over it first,
  // so the drag that lands there takes the same path as one that stopped there.
  if (target !== null && target !== drag.target) {
    if (drag.target !== null) dispatch(dragEvent("dragleave", dt, x, y, mods, false), drag.target);
    drag.target = target;
    drag.accepted = false;
    enterAt(target, dt, x, y, mods);
    drag.accepted = overAt(target, dt, x, y, mods);
  }
  if (target !== null && drag.accepted) {
    const drop = dragEvent("drop", dt, x, y, mods, true);
    dispatch(drop, target);
  }
  const end = dragEvent("dragend", dt, x, y, mods, false);
  dispatch(end, source);
  drag.active = false;
  drag.candidate = null;
  drag.source = null;
  drag.dataTransfer = null;
  drag.target = null;
  drag.accepted = false;
  return true;
}

/** The MIME type a file's name suggests, for a drop's File; "" when the name says nothing. */
export function fileTypeNamed(name: string): string {
  const dot = name.lastIndexOf(".");
  if (dot < 0) return "";
  const ext = name.slice(dot + 1).toLowerCase();
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "gif") return "image/gif";
  if (ext === "svg") return "image/svg+xml";
  if (ext === "webp") return "image/webp";
  if (ext === "txt") return "text/plain";
  if (ext === "html" || ext === "htm") return "text/html";
  if (ext === "css") return "text/css";
  if (ext === "js" || ext === "mjs") return "text/javascript";
  if (ext === "json") return "application/json";
  if (ext === "pdf") return "application/pdf";
  if (ext === "md") return "text/markdown";
  if (ext === "csv") return "text/csv";
  return "";
}

/** A File for a path on disk, with the size the file has there. */
export function fileFromPath(path: string): File {
  const slash = path.lastIndexOf("/");
  const name = slash < 0 ? path : path.slice(slash + 1);
  const size = hostFileSize(path);
  return new File(name, size < 0 ? 0 : size, fileTypeNamed(name), 0, path);
}

/**
 * A drag from outside the app was dropped at a point, carrying these files. The element under
 * the point hears dragenter, dragover and — when it takes the drag — drop, as a drag inside the
 * app would send them, and nothing hears dragend: the drag began outside.
 */
export function dropFilesAt(x: number, y: number, target: Node | null, files: File[], mods: number = 0): void {
  const dt = new DataTransfer();
  dt.files = files;
  // The drag began outside the app, where a copy is what dragging files offers.
  dt.effectAllowed = "copy";
  const at = target === null ? document.documentElement : target;
  enterAt(at, dt, x, y, mods);
  if (overAt(at, dt, x, y, mods)) dispatch(dragEvent("drop", dt, x, y, mods, true), at);
}

/** The files the host's drop carries, read off the drop that arrived. */
export function hostDropFiles(): File[] {
  const files: File[] = [];
  const count = hostDropFileCount();
  for (let i = 0; i < count; i++) {
    let name = "";
    let path = "";
    hostDropFileName(i, (value) => {
      name = value;
    });
    hostDropFilePath(i, (value) => {
      path = value;
    });
    if (path === "") continue;
    const size = hostFileSize(path);
    files.push(new File(name, size < 0 ? 0 : size, fileTypeNamed(name), 0, path));
  }
  return files;
}
