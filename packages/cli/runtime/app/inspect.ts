// Dev builds only: the data the dev inspector asks for. The `native dev` process and the app
// share a directory; a request file asks for a snapshot of the page (the DOM, the styles, the
// boxes, the layers and the frame times), and the app writes the answer beside it. Nothing here
// runs in a release build: mountDev starts it only when NATIVE_INSPECT_DIR names that directory.

import { existsSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as P from "../../shared/props.ts";
import { Element, Node, document, getComputedStyle, invalidatePaint } from "../dom.ts";
import { viewport } from "../viewport.ts";
import { devHighlight, paintLayers } from "../paint.ts";
import { frameTimes, recordFrames } from "../frame-times.ts";
import { hostSnapshot } from "../host.ts";
import { paintPage } from "./mount.ts";

/** How often the app looks for a request from the inspector. */
const POLL_MS = 25;

/** The properties the inspector's style panel shows, in the order it lists them. */
const STYLE_PROPERTIES = [
  "display", "position", "top", "right", "bottom", "left", "float", "clear", "z-index",
  "width", "height", "min-width", "min-height", "max-width", "max-height", "box-sizing", "aspect-ratio",
  "margin-top", "margin-right", "margin-bottom", "margin-left",
  "padding-top", "padding-right", "padding-bottom", "padding-left",
  "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
  "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
  "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
  "border-radius", "box-shadow", "outline",
  "background-color", "background-image", "background-position", "background-size", "background-repeat",
  "color", "font-family", "font-size", "font-weight", "font-style", "line-height", "letter-spacing", "word-spacing",
  "text-align", "text-decoration", "text-transform", "text-overflow", "white-space", "vertical-align", "direction",
  "overflow-x", "overflow-y", "visibility", "opacity", "transform", "transform-origin", "perspective",
  "filter", "backdrop-filter", "mix-blend-mode", "isolation", "clip-path", "mask-image",
  "flex-direction", "flex-wrap", "justify-content", "align-items", "align-content", "align-self", "gap", "row-gap", "column-gap", "order",
  "grid-template-columns", "grid-template-rows", "grid-column", "grid-row",
  "content", "cursor", "pointer-events", "user-select", "writing-mode",
];

/** The pseudo-elements the tree shows as children of their element. */
const PSEUDOS: { kind: number; name: string }[] = [
  { kind: P.PE_BEFORE, name: "::before" },
  { kind: P.PE_AFTER, name: "::after" },
  { kind: P.PE_MARKER, name: "::marker" },
  { kind: P.PE_PLACEHOLDER, name: "::placeholder" },
  { kind: P.PE_BACKDROP, name: "::backdrop" },
];

/** One node in the inspector's tree, as plain data. */
interface InspectNode {
  id: number;
  parent: number;
  type: number;
  name: string;
  attrs: string[][];
  text: string;
  pseudo: string | null;
  rect: number[] | null;
  box: { margin: number[]; border: number[]; padding: number[] } | null;
  scroll: { top: number; left: number; width: number; height: number; clientWidth: number; clientHeight: number } | null;
  styles: { [name: string]: string };
  pseudos: string[];
  children: number[];
}

/** A layer the inspector's layer panel lists. */
interface InspectLayer {
  id: number;
  depth: number;
  reason: string;
  zIndex: number;
  name: string;
  rect: number[];
}

interface InspectSnapshot {
  title: string;
  width: number;
  height: number;
  time: number;
  root: number;
  nodes: InspectNode[];
  layers: InspectLayer[];
  frames: { frame: number; style: number; anim: number; layout: number; paint: number; total: number }[];
}

/** A length a computed style gives as a number of pixels; 0 for a keyword or an unset value. */
function px(value: string): number {
  const n = parseFloat(value);
  return isNaN(n) ? 0 : n;
}

function rectOf(el: Element): number[] {
  const r = el.getBoundingClientRect();
  return [r.x, r.y, r.width, r.height];
}

function attrsOf(el: Element): string[][] {
  const out: string[][] = [];
  for (const name of el.attributeNames()) {
    const value = el.getAttribute(name);
    if (value !== null) out.push([name, value]);
  }
  return out;
}

function styleMap(el: Element, pseudo: string | null): { [name: string]: string } {
  const style = getComputedStyle(el, pseudo === null ? "" : pseudo);
  const out: { [name: string]: string } = {};
  for (const name of STYLE_PROPERTIES) out[name] = style.getPropertyValue(name);
  return out;
}

function boxOf(styles: { [name: string]: string }): { margin: number[]; border: number[]; padding: number[] } {
  const sides = ["top", "right", "bottom", "left"];
  const margin: number[] = [];
  const border: number[] = [];
  const padding: number[] = [];
  for (const side of sides) {
    margin.push(px(styles["margin-" + side]));
    border.push(px(styles["border-" + side + "-width"]));
    padding.push(px(styles["padding-" + side]));
  }
  return { margin: margin, border: border, padding: padding };
}

/** A node's tree id: the node's own serial, or a negative one unique to a pseudo-element. */
function pseudoId(el: Node, kind: number): number {
  return -(el.serial * 100 + kind);
}

/** The pseudo-elements an element paints whose style the tree shows. */
function pseudoKinds(el: Node): { kind: number; name: string }[] {
  const out: { kind: number; name: string }[] = [];
  for (const pseudo of PSEUDOS) {
    for (const kid of el.kids) {
      if (kid.pseudoKind === pseudo.kind) {
        out.push(pseudo);
        break;
      }
    }
  }
  return out;
}

/** Serializes the page: the DOM with its boxes and computed styles, the layers, and the frames. */
export function snapshotPage(): InspectSnapshot {
  const nodes: InspectNode[] = [];
  const root = document.serial;
  const rootEntry: InspectNode = {
    id: root, parent: 0, type: 9, name: "#document", attrs: [], text: "", pseudo: null,
    rect: null, box: null, scroll: null, styles: {}, pseudos: [], children: [],
  };
  nodes.push(rootEntry);
  const walk = (parent: Node, parentId: number): void => {
    // `childNodes` gives an element whose text is its own the #text child a browser has.
    for (const node of parent.childNodes) {
      // A marker, ::before and the like are listed under the element that owns them.
      if (node.pseudoKind !== P.PE_NONE) continue;
      const entry: InspectNode = {
        id: node.serial,
        parent: parentId,
        type: node.nodeType,
        name: node.nodeType === 1 ? (node.localName === "" ? node.nodeName.toLowerCase() : node.localName)
          : node.nodeType === 10 ? "#doctype" : node.nodeName,
        attrs: [],
        text: node.nodeType === 10 ? node.nodeName
          : node.nodeType === 3 || node.nodeType === 8 ? String(node.textContent ?? "").slice(0, 2000) : "",
        pseudo: null,
        rect: null,
        box: null,
        scroll: null,
        styles: {},
        pseudos: [],
        children: [],
      };
      if (node instanceof Element) {
        entry.attrs = attrsOf(node);
        entry.rect = rectOf(node);
        entry.styles = styleMap(node, null);
        entry.box = boxOf(entry.styles);
        entry.scroll = {
          top: node.scrollTop, left: node.scrollLeft,
          width: node.scrollWidth, height: node.scrollHeight,
          clientWidth: node.clientWidth, clientHeight: node.clientHeight,
        };
        for (const pseudo of pseudoKinds(node)) {
          entry.pseudos.push(pseudo.name);
          const pid = pseudoId(node, pseudo.kind);
          nodes.push({
            id: pid,
            parent: entry.id,
            type: 1,
            name: pseudo.name,
            attrs: [],
            text: "",
            pseudo: pseudo.name,
            rect: entry.rect,
            box: null,
            scroll: null,
            styles: styleMap(node, pseudo.name),
            pseudos: [],
            children: [],
          });
        }
      }
      nodes.push(entry);
      if (nodes.length > 20000) return;
      const kids = node.childNodes;
      entry.children = kids.map((kid) => kid.serial);
      walk(node, entry.id);
    }
  };
  walk(document, root);
  rootEntry.children = document.childNodes.map((node) => node.serial);
  const layers: InspectLayer[] = [];
  const rootEl = document.documentElement;
  if (rootEl !== null) {
    for (const layer of paintLayers(rootEl)) {
      const el = layer.node;
      const name = el instanceof Element
        ? (el.localName === "" ? el.nodeName.toLowerCase() : el.localName) + (el.id === "" ? "" : "#" + el.id)
        : el.nodeName;
      layers.push({ id: el.serial, depth: layer.depth, reason: layer.reason, zIndex: layer.zIndex, name,
        rect: el instanceof Element ? rectOf(el) : [0, 0, 0, 0] });
    }
  }
  return {
    title: document.title,
    width: viewport.w,
    height: viewport.h,
    time: Date.now(),
    root,
    nodes,
    layers,
    frames: frameTimes.history.slice(),
  };
}

/** Finds a node by the id a snapshot gave it, including the pseudo-elements. */
function findBySerial(serial: number): Node | null {
  let hit: Node | null = null;
  const walk = (node: Node): void => {
    if (hit !== null) return;
    if (node.serial === serial) {
      hit = node;
      return;
    }
    for (const kid of node.kids) walk(kid);
  };
  walk(document);
  return hit;
}

/** The element and pseudo a snapshot id names, for a style or highlight request. */
function elementOf(id: number): { el: Element; pseudo: string | null } | null {
  if (id >= 0) {
    const node = findBySerial(id);
    return node instanceof Element ? { el: node, pseudo: null } : null;
  }
  // A pseudo-element's id packs its element's serial and the pseudo kind's index.
  const packed = -id;
  const kindIndex = packed % 100;
  const serial = (packed - kindIndex) / 100;
  const node = findBySerial(serial);
  if (!(node instanceof Element)) return null;
  const pseudo = PSEUDOS.find((p) => p.kind === kindIndex);
  return pseudo === undefined ? null : { el: node, pseudo: pseudo.name };
}

/** The box a highlight should draw for a node: its border box in viewport coordinates. */
function boxOfNode(id: number): { x: number; y: number; w: number; h: number } | null {
  const found = elementOf(id);
  if (found === null) return null;
  const r = found.el.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
}

/** One request from the inspector and its answer. */
interface Inspection {
  id: number;
  op: string;
  nodeId?: number;
  selector?: string;
  path?: string;
}

function answer(req: Inspection): unknown {
  if (req.op === "snapshot") return snapshotPage();
  if (req.op === "query") {
    const el = document.querySelector(req.selector ?? "");
    return el === null ? 0 : el.serial;
  }
  if (req.op === "style") {
    const found = elementOf(req.nodeId ?? 0);
    return found === null ? null : styleMap(found.el, found.pseudo);
  }
  if (req.op === "box") {
    const found = elementOf(req.nodeId ?? 0);
    if (found === null) return null;
    const styles = styleMap(found.el, found.pseudo);
    return { rect: rectOf(found.el), box: boxOf(styles) };
  }
  if (req.op === "highlight") {
    const box = boxOfNode(req.nodeId ?? 0);
    devHighlight.box = box;
    invalidatePaint();
    return box !== null;
  }
  if (req.op === "clear") {
    devHighlight.box = null;
    invalidatePaint();
    return true;
  }
  if (req.op === "screenshot") {
    const path = req.path ?? join(process.env.NATIVE_INSPECT_DIR ?? "", "screenshot.png");
    // The display list may still be the previous frame's: paint what the page is now.
    paintPage();
    const ok = hostSnapshot(path, viewport.w, viewport.h, 2);
    return { ok: ok === 1, path };
  }
  if (req.op === "ping") return true;
  return null;
}

function writeAnswer(dir: string, id: number, ok: boolean, result: unknown): void {
  const file = join(dir, `res-${id}.json`);
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify({ id, ok, result }));
  renameSync(tmp, file);
}

/**
 * Starts answering the inspector's requests. The dev command creates the directory and writes a
 * request per file: `req-<id>.json`. The answer goes to `res-<id>.json` beside it.
 */
export function startInspector(dir: string): void {
  if (dir === "") return;
  recordFrames(true);
  const poll = (): void => {
    let names: string[] = [];
    try {
      names = readdirSync(dir);
    } catch {
      names = [];
    }
    const requests = names.filter((n) => n.startsWith("req-") && n.endsWith(".json")).sort();
    for (const name of requests) {
      const file = join(dir, name);
      let req: Inspection | null = null;
      try {
        req = JSON.parse(readFileSync(file, "utf8")) as Inspection;
      } catch {
        req = null;
      }
      if (req !== null && typeof req.id === "number" && typeof req.op === "string") {
        let ok = true;
        let result: unknown = null;
        try {
          result = answer(req);
        } catch (err) {
          ok = false;
          result = err instanceof Error ? err.message : String(err);
        }
        writeAnswer(dir, req.id, ok, result);
      }
      rmSync(file, { force: true });
    }
    setTimeout(poll, POLL_MS);
  };
  poll();
}
