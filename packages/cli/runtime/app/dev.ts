// Dev builds only: mounts the page through the compiled tables, then applies recompiled
// HTML/CSS tables to the live DOM as they change. A release build never imports this module,
// so none of it is linked into, or run by, a release executable.

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { HTMLElement, HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, Node, document, invalidateStyle, setFocus } from "../dom.ts";
import * as P from "../../shared/props.ts";
import type { AppTables } from "./mount.ts";
import { applyTables, createNode, devKeep, initNode, keepCompiledNodes, mount, fontFace, registerFontFace, resetPage } from "./mount.ts";
import type { DevFiles } from "./dev-watch.ts";
import { readTables as readTableFile, readToken, watchFiles } from "./dev-watch.ts";
import { onFirstFrame } from "./frame-ready.ts";
import { showCoverage } from "./dev-overlay.ts";
import { startInspector } from "./inspect.ts";
import { installErrorReporting } from "./source-map.ts";

/** The compiled nodes, in the current tables' order, and the tables they were built from. */
let nodes: Node[] = [];
let tables: AppTables | null = null;

/** The fonts the host already knows, so a reload doesn't register the same file twice. */
const knownFonts: Set<string> = new Set();

/** The state file a relaunch hands values through. Empty outside `native dev`. */
let stateFile = "";
/** The dev command's files, empty outside `native dev`. */
const files: DevFiles = {
  dataFile: "", data: "", ctlFile: "", ctl: "", scriptsFile: "", scripts: "", findingsFile: "", findings: "",
};

const EMPTY_STATE = '{"inputs":[],"scroll":[],"focus":"","caret":""}';

/** Form values, scroll offsets and focus to carry across a relaunch, as flat [id, value, checked]
 *  and [id, top, left] lists plus the focused element and its caret. Only elements with an id can
 *  be found again in the new process. */
interface SavedState {
  inputs: string[];
  scroll: string[];
  focus: string;
  caret: string;
}

function saveState(): void {
  if (stateFile === "") return;
  const inputs: string[] = [];
  const scroll: string[] = [];
  let focus = "";
  let caret = "";
  for (const node of nodes) {
    if (!(node instanceof HTMLElement) || node.id === "") continue;
    if (node instanceof HTMLInputElement) {
      inputs.push(node.id, node.value, node.checked ? "1" : "0");
    } else if (node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement) {
      inputs.push(node.id, node.value, "0");
    }
    if (node.scrollTop > 0 || node.scrollLeft > 0) {
      scroll.push(node.id, String(node.scrollTop), String(node.scrollLeft));
    }
  }
  const active = document.activeElement;
  if (active instanceof HTMLElement && active.id !== "") {
    focus = active.id;
    if (active instanceof HTMLInputElement) caret = active.selectionStart + "," + active.selectionEnd;
  }
  writeFileSync(stateFile, JSON.stringify({ inputs: inputs, scroll: scroll, focus: focus, caret: caret }));
}

function restoreState(): void {
  if (stateFile === "" || !existsSync(stateFile)) return;
  const state = JSON.parse(readFileSync(stateFile, "utf8")) as SavedState;
  for (let i = 0; i + 2 < state.inputs.length; i += 3) {
    const el = document.getElementById(state.inputs[i]);
    if (el instanceof HTMLInputElement) {
      el.value = state.inputs[i + 1];
      el.checked = state.inputs[i + 2] === "1";
    } else if (el instanceof HTMLTextAreaElement) {
      el.value = state.inputs[i + 1];
    } else if (el instanceof HTMLSelectElement) {
      el.value = state.inputs[i + 1];
    }
  }
  for (let i = 0; i + 2 < state.scroll.length; i += 3) {
    const el = document.getElementById(state.scroll[i]);
    if (el !== null) {
      // Restoring the page's state puts the box back at once, whatever its scroll-behavior says.
      el.scrollInstant(Number(state.scroll[i + 2]), Number(state.scroll[i + 1]));
    }
  }
  const focus = state.focus ?? "";
  if (focus !== "") {
    const el = document.getElementById(focus);
    if (el !== null) {
      setFocus(el);
      const caret = state.caret ?? "";
      if (el instanceof HTMLInputElement && caret !== "") {
        const at = caret.split(",");
        el.setSelectionRange(Number(at[0]), Number(at[1]));
      }
    }
  }
  // The state belongs to the relaunch that asked for it.
  writeFileSync(stateFile, EMPTY_STATE);
}

// ---------------------------------------------------------------------------
// Applying recompiled tables

/** The nodes a parent holds, in table order, for the two table sets being compared. */
function childLists(t: AppTables): number[][] {
  const out: number[][] = [];
  for (let i = 0; i < t.tags.length; i++) out.push([]);
  for (let i = 1; i < t.tags.length; i++) {
    const parent = t.parents[i];
    if (parent >= 0 && parent < out.length) out[parent].push(i);
  }
  return out;
}

/** Whether two tables describe the same tree shape: same tags under the same parents. When
 *  they do, every node keeps its place and only its data needs updating. */
function sameShape(a: AppTables, b: AppTables): boolean {
  if (a.tags.length !== b.tags.length) return false;
  for (let i = 0; i < a.tags.length; i++) {
    if (a.tags[i] !== b.tags[i] || a.parents[i] !== b.parents[i]) return false;
  }
  return true;
}

/** The identity two runs of siblings are matched by: the tag and the id as written. */
function key(t: AppTables, i: number): string {
  return t.tags[i] + "\u0000" + t.ids[i];
}

/**
 * For each child of the new table, the index of the old child it matches, or -1. Matching is a
 * longest common subsequence of the identity keys, so inserting one element doesn't renumber
 * every sibling after it.
 */
function matches(before: string[], after: string[]): number[] {
  const m = before.length;
  const n = after.length;
  const dp: number[][] = [];
  for (let i = 0; i <= m; i++) {
    const row: number[] = [];
    for (let j = 0; j <= n; j++) row.push(0);
    dp.push(row);
  }
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = before[i] === after[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out: number[] = [];
  for (let j = 0; j < n; j++) out.push(-1);
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (before[i] === after[j]) {
      out[j] = i;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}

function sameStrings(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function attrValue(attrs: string[], name: string): string | null {
  for (let i = 0; i + 1 < attrs.length; i += 2) if (attrs[i] === name) return attrs[i + 1];
  return null;
}

/** Applies the attributes the markup changed: names it dropped, values it rewrote, names it
 *  added. Attributes a script set and the markup never named are left alone. */
function applyAttrs(el: HTMLElement, before: string[], after: string[]): void {
  for (let i = 0; i + 1 < before.length; i += 2) {
    const value = attrValue(after, before[i]);
    if (value === null) el.removeAttribute(before[i]);
    else if (value !== before[i + 1]) el.setAttribute(before[i], value);
  }
  for (let i = 0; i + 1 < after.length; i += 2) {
    if (attrValue(before, after[i]) === null) el.setAttribute(after[i], after[i + 1]);
  }
}

/**
 * Moves one surviving node onto the new tables. Values the markup didn't change are not
 * rewritten, so input text and classes a script set stay as they are.
 */
function updateNode(node: Node, before: AppTables, pi: number, after: AppTables, i: number): void {
  node.rules = after.rules[i];
  node.sensitiveStates = after.states[i];
  if (node.isTextNode) {
    if (node.ownText !== after.text[i]) node.textContent = after.text[i];
    return;
  }
  if (!(node instanceof HTMLElement)) return;
  if (before.ids[pi] !== after.ids[i]) node.id = after.ids[i];
  if (!sameStrings(before.classes[pi], after.classes[i])) node.className = after.classes[i].join(" ");
  if (!sameStrings(before.attrs[pi], after.attrs[i])) applyAttrs(node, before.attrs[pi], after.attrs[i]);
  if (before.style[pi] !== after.style[i]) {
    if (after.style[i] === "") node.removeAttribute("style");
    else node.setAttribute("style", after.style[i]);
  }
  // A text-only element keeps its text on the element; a pseudo box's text is generated.
  if (node.ownText !== after.text[i]) node.ownText = after.text[i];
  const oldImage = before.nodeImages[pi];
  const newImage = after.nodeImages[i];
  const oldPath = oldImage >= 0 && oldImage < before.imageFiles.length ? before.imageFiles[oldImage] : "";
  const newPath = newImage >= 0 && newImage < after.imageFiles.length ? after.imageFiles[newImage] : "";
  if (oldPath !== newPath) {
    node.imagePath = newPath;
    node.dispGen = -1;
  }
}

/**
 * Applies the new tables to the live tree. When the tree shape is unchanged this only updates
 * node data; otherwise it matches children by tag and id, reuses the ones that stayed, and
 * creates or detaches only what the markup added or removed.
 */
function applyNodes(after: AppTables, before: AppTables): Node[] {
  if (nodes.length === after.tags.length && nodes.length > 0 && sameShape(before, after)) {
    for (let i = 0; i < nodes.length; i++) updateNode(nodes[i], before, i, after, i);
    return nodes;
  }

  const out: Node[] = [];
  const compiled: Set<Node> = new Set();
  const beforeKids = childLists(before);
  const afterKids = childLists(after);
  // The doctype nodes a build emits come first in the tables; the document element follows them
  // and the doctype nodes belong to the document beside it, as mount() puts them.
  let rootIdx = 0;
  while (rootIdx < after.tags.length && after.tags[rootIdx].startsWith("#doctype:")) rootIdx++;
  let root: Node;
  let beforeRoot = -1;
  if (nodes.length > rootIdx && before.tags[rootIdx] === after.tags[rootIdx] && before.ids[rootIdx] === after.ids[rootIdx]) {
    root = nodes[rootIdx];
    beforeRoot = rootIdx;
    updateNode(root, before, rootIdx, after, rootIdx);
  } else {
    root = createNode(after, rootIdx);
    initNode(after, rootIdx, root);
    root.parentNode = document;
    document.documentElement = root as HTMLElement;
    // A head a script made belonged to the root that was replaced.
    document.headEl = null;
  }
  out[rootIdx] = root;
  compiled.add(root);
  // The doctype nodes stay the same nodes while the doctype does, and the document keeps them
  // ahead of its element.
  document.kids = [];
  for (let i = 0; i < rootIdx; i++) {
    let dt = nodes[i];
    if (dt === undefined || before.tags[i] !== after.tags[i]) {
      dt = createNode(after, i);
      initNode(after, i, dt);
    } else {
      updateNode(dt, before, i, after, i);
    }
    dt.parentNode = document;
    document.kids.push(dt);
    out[i] = dt;
    compiled.add(dt);
  }
  document.kids.push(root);

  const walk = (parent: Node, ni: number, pi: number): void => {
    const olds = pi >= 0 ? beforeKids[pi] : [];
    const news = afterKids[ni];
    const oldsKeys: string[] = [];
    const newsKeys: string[] = [];
    for (const i of olds) oldsKeys.push(key(before, i));
    for (const i of news) newsKeys.push(key(after, i));
    const match = matches(oldsKeys, newsKeys);
    const used: Set<number> = new Set();
    const kids: Node[] = [];
    let structural = false;
    for (let j = 0; j < news.length; j++) {
      const i = news[j];
      let child: Node;
      if (match[j] >= 0) {
        const oi = olds[match[j]];
        used.add(match[j]);
        child = nodes[oi];
        updateNode(child, before, oi, after, i);
      } else {
        child = createNode(after, i);
        initNode(after, i, child);
        child.parentNode = parent;
        structural = true;
      }
      out[i] = child;
      compiled.add(child);
      kids.push(child);
      if (afterKids[i].length > 0) walk(child, i, match[j] >= 0 ? olds[match[j]] : -1);
    }
    for (let j = 0; j < olds.length; j++) {
      if (used.has(j)) continue;
      const gone = nodes[olds[j]];
      if (gone.parentNode === parent) {
        gone.parentNode = null;
        structural = true;
      }
      if (parent instanceof HTMLElement && parent.markerPseudo === gone) parent.markerPseudo = null;
    }
    if (!structural) return;
    // Put the children back in the order the DOM defines: a marker, ::before, the content,
    // any nodes the script added, then ::after.
    const content: Node[] = [];
    let marker: Node | null = null;
    let beforeBox: Node | null = null;
    let afterBox: Node | null = null;
    for (const k of kids) {
      if (k.pseudoKind === P.PE_MARKER) marker = k;
      else if (k.pseudoKind === P.PE_BEFORE) beforeBox = k;
      else if (k.pseudoKind === P.PE_AFTER) afterBox = k;
      else content.push(k);
    }
    const runtime: Node[] = [];
    for (const k of parent.kids) {
      if (!compiled.has(k) && k.parentNode === parent) runtime.push(k);
    }
    parent.kids.length = 0;
    if (marker !== null) parent.kids.push(marker);
    if (beforeBox !== null) parent.kids.push(beforeBox);
    for (const k of content) parent.kids.push(k);
    for (const k of runtime) parent.kids.push(k);
    if (afterBox !== null) parent.kids.push(afterBox);
    if (marker !== null && parent instanceof HTMLElement) parent.markerPseudo = marker as HTMLElement;
  };
  walk(root, rootIdx, beforeRoot);
  return out;
}

/** The key a face is known by: its sources and the family, weight range and style it covers. */
function faceKey(t: AppTables, i: number): string {
  const face = fontFace(t, i);
  return `${face.path}\u0000${face.locals.join("\u0000")}\u0000${face.family}\u0000${face.lo}\u0000${face.hi}\u0000${face.style}`;
}

function rememberFonts(t: AppTables): void {
  for (let i = 0; i < t.fontFiles.length; i++) knownFonts.add(faceKey(t, i));
}

/** Registers the fonts the newly compiled tables added; the ones already known stay as they are. */
function registerNewFonts(t: AppTables): void {
  for (let i = 0; i < t.fontFiles.length; i++) {
    const key = faceKey(t, i);
    if (knownFonts.has(key)) continue;
    knownFonts.add(key);
    registerFontFace(t, i);
  }
}

/** Reads the recompiled tables and applies them to the page that is already mounted. */
function reload(): void {
  if (tables === null) return;
  const next = readTableFile(files, tables);
  applyTables(next);
  registerNewFonts(next);
  if (document.titleText !== next.title) document.title = next.title;
  nodes = applyNodes(next, tables);
  tables = next;
  // A body the markup replaced has to become the document's body again.
  for (const node of nodes) {
    if (node instanceof HTMLElement && node.tagName === "BODY") {
      document.body = node;
      break;
    }
  }
  invalidateStyle();
}

/** Mounts a dev build's page, reloading it in place as the dev command recompiles HTML/CSS. */
export function mountDev(compiled: AppTables): void {
  // The dev command times an edit to the first frame this process paints; a release build has no
  // file to write and never sets the hook.
  const readyFile = process.env.NATIVE_DEV_READY ?? "";
  // A window the app opened inherits the variable but isn't the edit's screen.
  const secondary = (process.env.NATIVE_WINDOW_URL ?? "") !== "" || (process.env.NATIVE_WINDOW_OPENER ?? "") !== "";
  if (readyFile !== "" && !secondary) {
    onFirstFrame(() => {
      const tmp = readyFile + ".tmp";
      writeFileSync(tmp, String(Date.now()));
      renameSync(tmp, readyFile);
    });
  }
  files.dataFile = process.env.NATIVE_DEV_TABLES ?? "";
  stateFile = process.env.NATIVE_DEV_STATE ?? "";
  files.ctlFile = process.env.NATIVE_DEV_CTL ?? "";
  files.scriptsFile = process.env.NATIVE_DEV_SCRIPTS ?? "";
  files.findingsFile = process.env.NATIVE_DEV_FINDINGS ?? "";
  // Installed before the page mounts, so an exception the app's first module throws is reported
  // against the app's own file and line.
  installErrorReporting(process.env.NATIVE_DEV_SOURCES ?? "");
  keepCompiledNodes();
  const first = readTableFile(files, compiled);
  mount(first);
  rememberFonts(first);
  tables = first;
  if (devKeep.nodes !== null) nodes = devKeep.nodes;
  restoreState();
  // The inspector reads the page this process mounted; nothing answers when `native dev` wasn't
  // asked for one.
  startInspector(process.env.NATIVE_INSPECT_DIR ?? "");
  // A relaunch leaves its restart token on disk; the one there now belongs to this process.
  files.ctl = readToken(files.ctlFile);
  files.scripts = readToken(files.scriptsFile);
  files.findings = readToken(files.findingsFile);
  if (files.findings !== "") showCoverage(files.findings);
  if (files.dataFile !== "") {
    watchFiles(files, reload, () => {
      // The dev command is about to relaunch the executable: hand it this process's state.
      saveState();
      process.exit(0);
    }, () => scriptsHandler?.(), () => showCoverage(files.findings));
  }
}

/** The island's bundle reload, installed by onScripts once the host has a loader. */
let scriptsHandler: (() => void) | null = null;

/**
 * The island side of `native dev`: runs the app's first bundle, then every bundle the dev
 * command writes, in the page that is already open. A page reload is a markup reload plus a
 * script reload: the tables are re-read and mounted from scratch, since the scripts built the
 * document they ran against.
 */
export function onScripts(loader: { run(file: string): string; reset(): void }): void {
  const bundle = process.env.NATIVE_DEV_BUNDLE ?? "";
  const report = (text: string): void => {
    if (text === "") return;
    process.stderr.write(`native: Uncaught ${text}\n`);
  };
  // A bundle that was never written comes from a first build that failed: the dev command
  // printed why, and reading the missing file would only add an ENOENT stack to it.
  if (bundle !== "" && !existsSync(bundle)) process.stderr.write(`native: no script bundle was written, so the page's scripts are not running\n`);
  else report(loader.run(bundle));
  if (files.scriptsFile === "") return;
  scriptsHandler = () => {
    const token = files.scripts;
    try {
      saveState();
      loader.reset();
      resetPage();
      if (tables !== null) {
        const next = readTableFile(files, tables);
        mount(next);
        tables = next;
        if (devKeep.nodes !== null) nodes = devKeep.nodes;
      }
      report(loader.run(bundle));
      restoreState();
    } finally {
      writeFileSync(files.scriptsFile + ".ack", token);
    }
  };
}
