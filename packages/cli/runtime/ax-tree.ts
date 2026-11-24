// The accessibility tree: what VoiceOver and other assistive clients walk. Built from the rendered
// boxes after layout, as a flat list of nodes (parent by index) that the host turns into its
// platform's accessible objects. An element is a node when it has something to say — a role to
// play, a name, a value, a click to take — and its subtree is skipped when style or ARIA hides it.
//
// Nothing is built until a client asks: the host reports the first query (hostAxActive), and
// until then a frame spends nothing here beyond one flag read.

import * as P from "../shared/props.ts";
import { Element, Node, document, invalidatePaint, setAxChangeHook, setAxGeometryHook, setFocus, setFocusChangedHook } from "./dom.ts";
import { accessibleNode, computedRole } from "./a11y.ts";
import { absolutePosition } from "./layout.ts";
import { hostAxActive, hostAxAnnounce, hostAxTree, hostAxValueChanged } from "./host.ts";

/** One node of the accessibility tree, as the host receives it. Frames are in CSS px from the
 *  view's top-left corner. */
export interface AxNode {
  id: number;
  parent: number;
  /** The node's identity across trees: the same element keeps its uid from one tree to the next,
   *  so a host can keep the object a client holds. A text stop has its owner's, negated. */
  uid: number;
  role: string;
  subrole: string;
  label: string;
  value: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** The element can take keyboard focus. */
  focusable: boolean;
  focused: boolean;
  disabled: boolean;
  /** -1 for unchecked, 1 for checked, 0 when the role has no checked state. */
  checked: number;
  /** A heading's level, or 0. */
  level: number;
  valueNow: number;
  valueMin: number;
  valueMax: number;
  /** A field's caret or selection, and the line it sits on; -1 for anything that isn't a field. */
  selStart: number;
  selEnd: number;
  selLine: number;
  /** How many characters the value holds. */
  chars: number;
  /** The element's id attribute. */
  domId: string;
  /** The description accname computes: aria-describedby, else a title that isn't the name. */
  description: string;
  /** A field's placeholder: the placeholder attribute, else aria-placeholder. */
  placeholder: string;
  /** A link's href, resolved against the document. */
  url: string;
  /** aria-roledescription, when the page gives one. */
  roleDescription: string;
  /** -1 when the state doesn't apply, else 0 or 1. */
  expanded: number;
  selected: number;
  /** aria-pressed: -1 when it doesn't apply, 0 or 1, and 2 for mixed. */
  pressed: number;
  /** A checkbox in the mixed state; `checked` is -1 then. */
  mixed: boolean;
  required: boolean;
  readonly: boolean;
  /** A text field that takes more than one line: a textarea, or aria-multiline. */
  multiline: boolean;
  /** What a client can do to the node, as AXA_* bits. */
  actions: number;
}

/** The actions a node takes, as AxNode.actions carries them. */
export const AXA_PRESS = 1;
export const AXA_FOCUS = 2;
export const AXA_SET_VALUE = 4;
export const AXA_INSERT_TEXT = 8;
export const AXA_INCREMENT = 16;
export const AXA_SHOW_MENU = 32;

let stale = true;
/** True while only boxes moved: the nodes, their roles and their names stand, their rects don't. */
let geometryStale = false;
/** The last tree handed to the host, kept so a frame that changes nothing costs nothing. */
let lastJson = "";
/** The last tree, so a frame that only moved boxes can update rects in place. */
let lastNodes: AxNode[] = [];
/** The element behind each node id of the last tree, so a focus request can name one. */
let nodeEls: (Element | null)[] = [];
/** The element each node's box belongs to: its own for a control or landmark, and the element a
 *  static-text stop was emitted for. A geometry-only frame reads its rect again. */
let nodeOwners: (Element | null)[] = [];
/** The element behind each uid of the last tree, for an action a client takes on one. */
let uidEls = new Map<number, Element>();
/** The next uid an element gets the first time a tree holds it. */
let nextUid = 1;

/** The stable id of an element's node, given the first time a tree holds it. */
function uidOf(el: Element): number {
  if (el.axUid === 0) el.axUid = nextUid++;
  return el.axUid;
}

/** The element a node's uid names in the last tree, if it is still in the page. */
export function axElement(uid: number): Element | null {
  const el = uidEls.get(uid);
  return el !== undefined && el.isConnected ? el : null;
}

// The tree's focused node follows the document's: a focus change rebuilds it on the next frame,
// and so does a field edit, whose value the tree carries.
setFocusChangedHook(axDirty);
setAxChangeHook(axDirty);
setAxGeometryHook(axGeometryDirty);

/** Marks the accessibility tree out of date; the next frame rebuilds it. */
export function axDirty(): void {
  stale = true;
}

/**
 * Marks only the boxes out of date: a scroll, a transform, an opacity group. The host takes the
 * tree as one JSON text, so an update costs the size of the tree; past a small window a frame
 * leaves the rects as they were rather than send that text on every scroll.
 */
export function axGeometryDirty(): void {
  if (stale || lastNodes.length > 256) return;
  geometryStale = true;
}

/** The role an element plays for assistive technology, as HTML-AAM gives it: the page's own
 *  `role` when it names one, else the tag's. The engine that computes it is runtime/a11y.ts. */
export function axRole(el: Element): string {
  return computedRole(el);
}

/** The text an element's subtree holds, whitespace collapsed: its own text and its children's. */
export function axText(el: Element): string {
  let text = "";
  const take = (n: Node): void => {
    if (n.isTextNode) {
      text += n.ownText;
      return;
    }
    text += n.ownText;
    for (const c of n.kids) if (c.pseudoKind === P.PE_NONE) take(c);
  };
  take(el);
  return text.replace(/\s+/g, " ").trim();
}

/** The accessible name accname 1.2 computes for the element — aria-labelledby, aria-label, the
 *  native label of a control, then the content for the roles a browser names from it. */
export function axLabel(el: Element): string {
  return accessibleNode(el).name;
}

/** Roles a container keeps to itself: the walk passes their children up, since a paragraph or a
 *  layout box is not a stop of its own. */
const PASS_THROUGH: readonly string[] = ["", "generic", "presentation", "none", "paragraph",
  "rowgroup", "blockquote", "code", "emphasis", "strong", "subscript", "superscript", "time",
  "term", "definition"];

/** Roles whose content is their name, so a node that plays one has nothing below it to walk. */
const LEAF: readonly string[] = ["button", "link", "heading", "img", "checkbox", "radio", "textbox",
  "searchbox", "spinbutton", "combobox", "listbox", "slider", "menuitem", "menuitemcheckbox",
  "menuitemradio", "option", "progressbar", "meter", "switch", "tab", "treeitem"];

/** Roles a client presses: the widgets whose activation is their click. */
const PRESSABLE: readonly string[] = ["button", "link", "checkbox", "radio", "switch", "tab",
  "menuitem", "menuitemcheckbox", "menuitemradio", "option", "treeitem", "combobox"];

/** Whether the page listens for a click on the element itself, which makes it something a client
 *  can press even when its role says nothing, as a browser exposes a clickable element. */
function listensForClick(el: Element): boolean {
  const types = ["click", "mousedown", "mouseup", "pointerdown", "pointerup"];
  for (const t of types) {
    const list = el.listeners.get(t);
    if (list !== undefined && list.length > 0) return true;
  }
  return false;
}

/** Whether a subtree holds anything a screen reader stops at: a control, a landmark, an image,
 *  or an element the page takes clicks on. */
function hasSemanticKid(el: Element): boolean {
  for (const c of el.kids) {
    if (!(c instanceof Element) || c.pseudoKind !== P.PE_NONE) continue;
    if (PASS_THROUGH.indexOf(computedRole(c)) < 0 || listensForClick(c)) return true;
    if (hasSemanticKid(c)) return true;
  }
  return false;
}

/** The value a control exposes: a field's text, a control's state, a range's position. */
function axValue(el: Element): string {
  const given = el.getAttribute("aria-valuetext");
  if (given !== null && given !== "") return given;
  if (el.localName === "input" || el.localName === "textarea") {
    const v = (el as any).value;
    return v === undefined ? "" : String(v);
  }
  // A select that shows one option reads as the option it shows.
  if (el.localName === "select" && computedRole(el) === "combobox") {
    const select = el as any;
    const option = select.selectedIndex >= 0 ? select.options[select.selectedIndex] : null;
    return option === null || option === undefined ? "" : axText(option as Element);
  }
  return "";
}

/** Whether style and the tree around the element leave it out of the page's rendering at all. */
function hiddenFromAx(el: Element): boolean {
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return true;
  if (el.getAttribute("aria-hidden") === "true") return true;
  if (el.getAttribute("hidden") !== null) return true;
  let n: Node | null = el.parentElement;
  while (n !== null) {
    if (n instanceof Element && (n.getAttribute("aria-hidden") === "true" || n.inert)) return true;
    n = n.parentElement;
  }
  return false;
}

/** A text run's node: the words a block holds, which VoiceOver reads as static text. */
function textNode(label: string, parent: number, x: number, y: number, w: number, h: number): AxNode {
  return {
    id: 0, parent, uid: 0, role: "staticText", subrole: "", label, value: "",
    x, y, w, h, focusable: false, focused: false, disabled: false,
    checked: 0, level: 0, valueNow: NaN, valueMin: NaN, valueMax: NaN,
    selStart: -1, selEnd: -1, selLine: -1, chars: 0,
    domId: "", description: "", placeholder: "", url: "", roleDescription: "",
    expanded: -1, selected: -1, pressed: -1, mixed: false, required: false, readonly: false,
    multiline: false, actions: 0,
  };
}

function triState(v: boolean | null): number {
  return v === null ? -1 : v ? 1 : 0;
}

/** Whether a field takes typed text: a textbox that is neither read-only nor disabled. */
function editableText(el: Element, role: string, readonly: boolean, disabled: boolean): boolean {
  if (readonly || disabled) return false;
  if (role !== "textbox" && role !== "searchbox" && role !== "spinbutton" && role !== "combobox") return false;
  if (el.localName === "textarea") return true;
  if (el.localName !== "input") return false;
  const type = (el.getAttribute("type") ?? "text").toLowerCase();
  return type !== "range" && type !== "checkbox" && type !== "radio" && type !== "button" &&
    type !== "submit" && type !== "reset" && type !== "image" && type !== "color" && type !== "file";
}

/** Whether the element or an ancestor listens for contextmenu, so a client's menu request has
 *  somewhere to go. */
function hasMenu(el: Element): boolean {
  for (let n: Node | null = el; n !== null; n = n.parentNode) {
    if (!(n instanceof Element)) continue;
    const list = n.listeners.get("contextmenu");
    if ((list !== undefined && list.length > 0) || n.getAttribute("contextmenu") !== null) return true;
  }
  return false;
}

/** The actions a client may take on an element's node. */
function nodeActions(el: Element, role: string, readonly: boolean, disabled: boolean, valueNow: number | null): number {
  let bits = 0;
  if (!disabled && (PRESSABLE.indexOf(role) >= 0 || el.localName === "summary" || listensForClick(el))) bits |= AXA_PRESS;
  if ((el as any).isFocusable === true && !disabled) bits |= AXA_FOCUS;
  const editable = editableText(el, role, readonly, disabled);
  if (editable) bits |= AXA_SET_VALUE | AXA_INSERT_TEXT;
  if (!readonly && !disabled && (role === "slider" || role === "spinbutton") &&
    (valueNow !== null || el.localName === "input")) {
    bits |= AXA_INCREMENT;
    // A native range takes a value outright, as its value attribute does.
    if (el.localName === "input") bits |= AXA_SET_VALUE;
  }
  if (hasMenu(el)) bits |= AXA_SHOW_MENU;
  return bits;
}

/** A link's address, resolved as the page resolves it. */
function linkUrl(el: Element, role: string): string {
  if (role !== "link") return "";
  const href = (el as any).href;
  if (typeof href === "string") return href;
  return el.getAttribute("href") ?? "";
}

/** A field's caret, selection end, line, or value length (which = 0..3), or -1 when the element
 *  isn't a field. */
function fieldSelection(el: Element, which: number): number {
  if (el.localName !== "input" && el.localName !== "textarea") return which === 3 ? 0 : -1;
  const value = (el as any).value;
  const text = value === undefined || value === null ? "" : String(value);
  if (which === 3) return text.length;
  const start = (el as any).selectionStart;
  const end = (el as any).selectionEnd;
  const at = typeof start === "number" ? start : 0;
  const last = typeof end === "number" ? end : at;
  if (which === 0) return at;
  if (which === 1) return last;
  // The insertion line: how many newlines the value holds before the caret.
  let line = 0;
  for (let i = 0; i < at && i < text.length; i++) if (text[i] === "\n") line++;
  return line;
}

/** Builds the whole tree, in document order, parents before children. */
export function buildAxTree(): AxNode[] {
  const out: AxNode[] = [];
  const els: (Element | null)[] = [];
  const owners: (Element | null)[] = [];
  const root = document.documentElement;
  if (root === null || hiddenFromAx(root)) return out;
  liveRegions = [];
  const byUid = new Map<number, Element>();
  // A run of text is one static-text stop at the box it paints in.
  const emitText = (el: Element, parent: number): void => {
    const text = axText(el);
    if (text === "") return;
    const r = el.getBoundingClientRect();
    const t = textNode(text, parent, r.x, r.y, r.width, r.height);
    t.id = out.length + 1;
    t.uid = -uidOf(el);
    out.push(t);
    els.push(null);
    owners.push(el);
  };
  // A control is a leaf: its content is its name. A layout box passes its children up unless it
  // only holds presentational text, which becomes one static-text stop.
  const walk = (el: Element, parent: number): void => {
    if (hiddenFromAx(el)) return;
    // Role, name and states are the accessibility engine's (runtime/a11y.ts): the role HTML-AAM
    // gives the element, the name accname computes, and the state a screen reader reads.
    const ax = accessibleNode(el);
    const role = ax.role;
    const label = ax.name;
    const states = ax.states;
    if (states.live === "polite" || states.live === "assertive" || role === "status" ||
      role === "alert" || role === "log") {
      liveRegions.push({ el, urgent: states.live === "assertive" || role === "alert" });
    }
    const transparent = el.localName === "html" || el.localName === "body";
    // A box the page takes clicks on is a node, as a browser exposes it, whatever its role.
    if (transparent || (PASS_THROUGH.indexOf(role) >= 0 && label === "" && !listensForClick(el))) {
      // The document itself is the host's web area; the walk starts at what it holds.
      if (!hasSemanticKid(el)) {
        emitText(el, parent);
        return;
      }
    } else {
      // The border box as the page shows it: an inline box's own w/h are zero, and its rect is
      // the union of the line fragments it paints in.
      const r = el.getBoundingClientRect();
      const uid = uidOf(el);
      byUid.set(uid, el);
      const placeholder = el.getAttribute("placeholder") ?? el.getAttribute("aria-placeholder") ?? "";
      const multiline = el.localName === "textarea" || el.getAttribute("aria-multiline") === "true";
      const node: AxNode = {
        id: out.length + 1,
        parent,
        uid,
        role,
        subrole: "",
        label,
        value: axValue(el),
        x: r.x,
        y: r.y,
        w: r.width,
        h: r.height,
        focusable: (el as any).isFocusable === true || el.getAttribute("tabindex") !== null,
        focused: document.activeElement === el,
        disabled: states.disabled,
        checked: states.checked === true ? 1 : states.checked === false ? -1 : 0,
        level: states.level,
        valueNow: states.valueNow === null ? NaN : states.valueNow,
        valueMin: states.valueMin === null ? NaN : states.valueMin,
        valueMax: states.valueMax === null ? NaN : states.valueMax,
        selStart: fieldSelection(el, 0),
        selEnd: fieldSelection(el, 1),
        selLine: fieldSelection(el, 2),
        chars: fieldSelection(el, 3),
        domId: el.id,
        description: ax.description,
        placeholder,
        url: linkUrl(el, role),
        roleDescription: el.getAttribute("aria-roledescription") ?? "",
        expanded: triState(states.expanded),
        selected: triState(states.selected),
        pressed: states.pressed === "mixed" ? 2 : triState(states.pressed === null ? null : states.pressed === true),
        mixed: states.checked === "mixed",
        required: states.required,
        readonly: states.readonly,
        multiline,
        actions: nodeActions(el, role, states.readonly, states.disabled, states.valueNow),
      };
      out.push(node);
      els.push(el);
      owners.push(el);
      // A control's content is its name, so it is a leaf; a cell is one only while its content
      // is plain text — a button or field inside it has to stay reachable.
      if (LEAF.indexOf(role) >= 0 || (role === "cell" && !hasSemanticKid(el))) return;
      // A node nothing named shows its text as one static-text stop under it.
      if (label === "" && !hasSemanticKid(el)) {
        emitText(el, node.id);
        return;
      }
      for (const c of el.kids) if (c instanceof Element && c.pseudoKind === P.PE_NONE) walk(c, node.id);
      return;
    }
    for (const c of el.kids) if (c instanceof Element && c.pseudoKind === P.PE_NONE) walk(c, parent);
  };
  walk(root, 0);
  uidEls = byUid;
  nodeEls = els;
  nodeOwners = owners;
  return out;
}

/** Focuses the element the host's accessibility tree named, for VoiceOver's focus request. */
export function focusAxNode(id: number): void {
  const el = id > 0 && id <= nodeEls.length ? nodeEls[id - 1] : null;
  if (el !== null && el.isConnected) setFocus(el);
}

/** Puts a field's caret or selection where VoiceOver's text navigation asked: its node id, the
 *  range's location and length. */
export function selectAxRange(id: number, start: number, length: number): void {
  const el = id > 0 && id <= nodeEls.length ? nodeEls[id - 1] : null;
  if (el === null || !el.isConnected) return;
  if (el.localName !== "input" && el.localName !== "textarea") return;
  setFocus(el);
  const field = el as any;
  const text = field.value === undefined ? "" : String(field.value);
  const s = Math.max(0, Math.min(Math.round(start), text.length));
  const e = Math.max(s, Math.min(s + Math.max(0, Math.round(length)), text.length));
  field.selectionStart = s;
  field.selectionEnd = e;
  invalidatePaint();
}

/**
 * Hands the host the tree when anything about it moved. The frame pipeline calls this after the
 * layout, so a query from VoiceOver never runs a style pass in the middle of AppKit's own.
 */
/** The text each live region held, and the value each control held, at the last tree. */
const liveText = new Map<Element, string>();
const fieldValues = new Map<Element, string>();
/** The live regions of the last tree: aria-live, or the roles a browser treats as live. */
let liveRegions: { el: Element; urgent: boolean }[] = [];

/** Announces what a live region now says, and tells the host which controls' values moved. The
 *  first tree a client gets announces nothing: what a region already said isn't a change. */
function reportChanges(nodes: AxNode[], first: boolean): void {
  for (const region of liveRegions) {
    if (first) break;
    const text = axText(region.el);
    if (text !== "" && text !== (liveText.get(region.el) ?? "")) hostAxAnnounce(text, region.urgent ? 1 : 0);
  }
  liveText.clear();
  for (const region of liveRegions) liveText.set(region.el, axText(region.el));
  // The node order is the walk's, so the elements line up with it.
  const values = new Map<Element, string>();
  for (let i = 0; i < nodes.length && i < nodeEls.length; i++) {
    const el = nodeEls[i];
    if (el === null) continue;
    const value = nodes[i].value;
    if (value === "") continue;
    values.set(el, value);
    const was = fieldValues.get(el);
    if (was !== undefined && was !== value) hostAxValueChanged(nodes[i].id);
  }
  fieldValues.clear();
  for (const [k, v] of values) fieldValues.set(k, v);
}

export function flushAx(): void {
  // No client has asked for the tree yet: the dirty flags keep standing, and the first frame after
  // a client's query builds it.
  if (hostAxActive() === 0) return;
  if (stale) {
    stale = false;
    geometryStale = false;
    const first = lastJson === "";
    const nodes = buildAxTree();
    lastNodes = nodes;
    const json = JSON.stringify(nodes);
    reportChanges(nodes, first);
    if (json === lastJson) return;
    lastJson = json;
    hostAxTree(json);
    return;
  }
  if (!geometryStale) return;
  geometryStale = false;
  // Only the boxes moved: read each node's own element again. A node whose element has left the
  // page is left as it was — the next structural change rebuilds the tree.
  const nodes = lastNodes;
  for (let i = 0; i < nodes.length; i++) {
    const el = i < nodeOwners.length ? nodeOwners[i] : null;
    if (el === null || !el.isConnected) continue;
    const r = el.getBoundingClientRect();
    nodes[i].x = r.x;
    nodes[i].y = r.y;
    nodes[i].w = r.width;
    nodes[i].h = r.height;
  }
  const json = JSON.stringify(nodes);
  if (json === lastJson) return;
  lastJson = json;
  hostAxTree(json);
}

/** Forgets the tree, as another page starts with one of its own. */
export function resetAx(): void {
  stale = true;
  geometryStale = false;
  lastNodes = [];
  nodeOwners = [];
  lastJson = "";
  // A host that hasn't been asked for a tree has none to empty: an empty one now would read to a
  // client as a page with nothing in it.
  if (hostAxActive() !== 0) hostAxTree("[]");
}
