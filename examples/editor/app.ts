// Draft, a contenteditable document editor in plain HTML, CSS and TypeScript. Formatting is done
// with the Selection and Range APIs directly — wrapping the selected range, changing the block
// around it, building lists and links — because the runtime's editing commands cover the clipboard
// only. The toolbar reflects the selection, Cmd+B/I/U apply commands, and the draft is kept in
// localStorage with a small undo history.

const doc = document.getElementById("doc") as HTMLElement;
const title = document.getElementById("title") as HTMLInputElement;
const saved = document.getElementById("saved")!;
const wordCount = document.getElementById("word-count")!;
const charCount = document.getElementById("char-count")!;
const selectionInfo = document.getElementById("selection-info")!;
const formatState = document.getElementById("format-state")!;
const linkDialog = document.getElementById("link-dialog") as HTMLDialogElement;
const linkUrl = document.getElementById("link-url") as HTMLInputElement;

const DOC_KEY = "draft.doc.v1";
const TITLE_KEY = "draft.title.v1";
const BLOCKS = ["P", "H1", "H2", "BLOCKQUOTE", "PRE"];

let saveTimer = 0;
// The last range inside the editor: pressing a toolbar button moves focus, and with it the
// selection, so a command restores this range before it edits.
let lastRange: Range | null = null;
let lastSnapshot = doc.innerHTML;
const undoStack: string[] = [];
const redoStack: string[] = [];

function clock(): string {
  const date = new Date();
  return (date.getHours() < 10 ? "0" + String(date.getHours()) : String(date.getHours())) + ":" +
    (date.getMinutes() < 10 ? "0" + String(date.getMinutes()) : String(date.getMinutes()));
}

function setStatus(text: string): void {
  saved.textContent = text;
}

function updateCounts(): void {
  const text = doc.textContent === null ? "" : doc.textContent.trim();
  const words = text === "" ? [] : text.split(/\s+/);
  wordCount.textContent = String(words.length) + (words.length === 1 ? " word" : " words");
  charCount.textContent = String(text.length) + (text.length === 1 ? " character" : " characters");
}

function save(): void {
  if (saveTimer !== 0) {
    clearTimeout(saveTimer);
    saveTimer = 0;
  }
  localStorage.setItem(DOC_KEY, doc.innerHTML);
  localStorage.setItem(TITLE_KEY, title.value);
  setStatus("Saved " + clock());
}

function saveSoon(): void {
  if (saveTimer !== 0) clearTimeout(saveTimer);
  saveTimer = window.setTimeout(save, 350);
}

function pushUndo(): void {
  undoStack.push(lastSnapshot);
  if (undoStack.length > 60) undoStack.shift();
  redoStack.length = 0;
}

function afterChange(): void {
  lastSnapshot = doc.innerHTML;
  updateCounts();
  refresh();
  saveSoon();
}

function undo(): void {
  if (undoStack.length === 0) return;
  redoStack.push(lastSnapshot);
  const previous = undoStack.pop();
  if (previous === undefined) return;
  doc.innerHTML = previous;
  lastSnapshot = previous;
  updateCounts();
  refresh();
  saveSoon();
}

function redo(): void {
  if (redoStack.length === 0) return;
  undoStack.push(lastSnapshot);
  const next = redoStack.pop();
  if (next === undefined) return;
  doc.innerHTML = next;
  lastSnapshot = next;
  updateCounts();
  refresh();
  saveSoon();
}

function selectionInside(): boolean {
  const sel = window.getSelection();
  if (sel === null || sel.rangeCount === 0) return false;
  const node = sel.anchorNode;
  return node !== null && doc.contains(node);
}

function selectedRange(): Range | null {
  const sel = window.getSelection();
  if (sel !== null && sel.rangeCount > 0 && selectionInside()) return sel.getRangeAt(0);
  return lastRange;
}

/** Puts the selection back on the last range the editor had, after a toolbar press moved it. */
function restoreSelection(range: Range): void {
  const sel = window.getSelection();
  if (sel === null) return;
  sel.removeAllRanges();
  sel.addRange(range);
}

/** The nearest block-level element around a node, inside the editor. */
function blockOf(node: Node | null): HTMLElement | null {
  let current: Node | null = node;
  while (current !== null && current !== doc) {
    if (current instanceof HTMLElement && BLOCKS.indexOf(current.tagName) >= 0) return current;
    current = current.parentNode;
  }
  return null;
}

/** Tags between the selection anchor and the editor, for the toolbar's pressed state. */
function activeTags(): string[] {
  const sel = window.getSelection();
  const tags: string[] = [];
  if (sel === null || !selectionInside()) return tags;
  let node: Node | null = sel.anchorNode;
  while (node !== null && node !== doc) {
    if (node instanceof HTMLElement) {
      const tag = node.tagName;
      if (tag === "STRONG" || tag === "B") tags.push("bold");
      else if (tag === "EM" || tag === "I") tags.push("italic");
      else if (tag === "U") tags.push("underline");
      else if (tag === "A") tags.push("link");
      else if (tag === "UL") tags.push("bullet list");
      else if (tag === "OL") tags.push("numbered list");
    }
    node = node.parentNode;
  }
  return tags;
}

function refreshSelection(): void {
  const sel = window.getSelection();
  if (sel === null || !selectionInside()) {
    selectionInfo.textContent = "no selection";
    return;
  }
  const length = sel.toString().length;
  selectionInfo.textContent = length === 0 ? "caret" : String(length) + " selected";
}

function pressed(id: string, on: boolean): void {
  const element = document.getElementById(id);
  if (element !== null) element.setAttribute("aria-pressed", on ? "true" : "false");
}

function refresh(): void {
  const sel = window.getSelection();
  if (sel !== null && sel.rangeCount > 0 && selectionInside()) lastRange = sel.getRangeAt(0).cloneRange();
  const tags = activeTags();
  const labels: string[] = [];
  if (tags.indexOf("bold") >= 0) labels.push("bold");
  if (tags.indexOf("italic") >= 0) labels.push("italic");
  if (tags.indexOf("underline") >= 0) labels.push("underline");
  if (tags.indexOf("bullet list") >= 0) labels.push("bullet list");
  if (tags.indexOf("numbered list") >= 0) labels.push("numbered list");
  if (tags.indexOf("link") >= 0) labels.push("link");
  formatState.textContent = labels.length === 0 ? "plain" : labels.join(" · ");
  pressed("bold", tags.indexOf("bold") >= 0);
  pressed("italic", tags.indexOf("italic") >= 0);
  pressed("underline", tags.indexOf("underline") >= 0);
  pressed("ul", tags.indexOf("bullet list") >= 0);
  pressed("ol", tags.indexOf("numbered list") >= 0);
  refreshSelection();
}

/** Wraps the selected range in a new element of the given tag and selects its contents. */
function wrapSelection(tag: string, attributes: { href?: string } | null = null): void {
  const range = selectedRange();
  if (range === null || range.collapsed) return;
  pushUndo();
  restoreSelection(range);
  const wrapper = document.createElement(tag);
  if (attributes !== null && attributes.href !== undefined) wrapper.setAttribute("href", attributes.href);
  const contents = range.extractContents();
  wrapper.appendChild(contents);
  range.insertNode(wrapper);
  const sel = window.getSelection();
  if (sel !== null) {
    const around = document.createRange();
    around.selectNodeContents(wrapper);
    sel.removeAllRanges();
    sel.addRange(around);
  }
  afterChange();
}

function unwrap(element: HTMLElement): void {
  const parent = element.parentNode;
  if (parent === null) return;
  while (element.firstChild !== null) parent.insertBefore(element.firstChild, element);
  parent.removeChild(element);
}

/** Removes the inline formatting inside the selection. */
function clearFormatting(): void {
  const range = selectedRange();
  if (range === null) return;
  pushUndo();
  restoreSelection(range);
  const nodes = doc.querySelectorAll("strong, b, em, i, u, a");
  for (let index = nodes.length - 1; index >= 0; index--) {
    const element = nodes[index];
    if (element instanceof HTMLElement && range.intersectsNode(element)) unwrap(element);
  }
  afterChange();
}

/** Changes the block around the selection, keeping its children. */
function setBlock(tag: string): void {
  const range = selectedRange();
  if (range === null) return;
  restoreSelection(range);
  const blocks: HTMLElement[] = [];
  for (let index = 0; index < doc.children.length; index++) {
    const child = doc.children[index];
    if (child instanceof HTMLElement && range.intersectsNode(child)) blocks.push(child);
  }
  if (blocks.length === 0) return;
  pushUndo();
  for (const block of blocks) {
    const replacement = document.createElement(tag);
    while (block.firstChild !== null) replacement.appendChild(block.firstChild);
    const parent = block.parentNode;
    if (parent !== null) parent.replaceChild(replacement, block);
  }
  afterChange();
}

/** Wraps the blocks the selection touches in a list, or unwraps a list it touches. */
function toggleList(kind: string): void {
  const range = selectedRange();
  if (range === null) return;
  pushUndo();
  restoreSelection(range);
  // A selection inside a list item unwraps the whole list back to paragraphs.
  let list: HTMLElement | null = null;
  let probe: Node | null = range.startContainer;
  while (probe !== null && probe !== doc) {
    if (probe instanceof HTMLElement && (probe.tagName === "UL" || probe.tagName === "OL")) {
      list = probe;
      break;
    }
    probe = probe.parentNode;
  }
  if (list !== null) {
    const parent = list.parentNode;
    if (parent !== null) {
      const items = list.querySelectorAll("li");
      for (let index = 0; index < items.length; index++) {
        const item = items[index];
        if (!(item instanceof HTMLElement)) continue;
        const paragraph = document.createElement("p");
        while (item.firstChild !== null) paragraph.appendChild(item.firstChild);
        parent.insertBefore(paragraph, list);
      }
      parent.removeChild(list);
    }
    afterChange();
    return;
  }
  const blocks: HTMLElement[] = [];
  for (let index = 0; index < doc.children.length; index++) {
    const child = doc.children[index];
    if (child instanceof HTMLElement && BLOCKS.indexOf(child.tagName) >= 0 && range.intersectsNode(child)) blocks.push(child);
  }
  if (blocks.length === 0) return;
  const created = document.createElement(kind);
  const first = blocks[0];
  const firstParent = first.parentNode;
  if (firstParent === null) return;
  firstParent.insertBefore(created, first);
  for (const block of blocks) {
    const item = document.createElement("li");
    while (block.firstChild !== null) item.appendChild(block.firstChild);
    created.appendChild(item);
    const parent = block.parentNode;
    if (parent !== null) parent.removeChild(block);
  }
  afterChange();
}

function openLink(): void {
  linkUrl.value = "";
  linkDialog.showModal();
  linkUrl.focus();
}

function applyLink(): void {
  const url = linkUrl.value.trim();
  if (!/^https?:\/\/\S+$/.test(url)) {
    setStatus("Enter a full URL");
    linkUrl.focus();
    return;
  }
  const range = selectedRange();
  if (range === null || range.collapsed) {
    setStatus("Select a word first");
    linkDialog.close();
    return;
  }
  wrapSelection("a", { href: url });
  linkDialog.close();
  setStatus("Link added");
}

document.getElementById("bold")!.addEventListener("click", () => wrapSelection("strong"));
document.getElementById("italic")!.addEventListener("click", () => wrapSelection("em"));
document.getElementById("underline")!.addEventListener("click", () => wrapSelection("u"));
document.getElementById("ul")!.addEventListener("click", () => toggleList("ul"));
document.getElementById("ol")!.addEventListener("click", () => toggleList("ol"));
document.getElementById("undo")!.addEventListener("click", undo);
document.getElementById("redo")!.addEventListener("click", redo);
document.getElementById("clear")!.addEventListener("click", clearFormatting);
document.getElementById("link-open")!.addEventListener("click", openLink);
document.getElementById("link-apply")!.addEventListener("click", applyLink);
document.getElementById("link-cancel")!.addEventListener("click", () => linkDialog.close());

const block = document.getElementById("block") as HTMLSelectElement;
block.addEventListener("change", () => {
  setBlock(block.value.toUpperCase());
});

// A press inside the editor focuses it: the runtime accepts the press as a text selection but a
// host with block children doesn't take the focus a typed key needs.
doc.addEventListener("pointerdown", () => { doc.focus(); });

doc.addEventListener("input", () => {
  pushUndo();
  setStatus("Editing…");
  afterChange();
});

title.addEventListener("input", () => {
  setStatus("Editing…");
  saveSoon();
});

document.addEventListener("selectionchange", refresh);

document.addEventListener("keydown", (event: KeyboardEvent) => {
  const accel = event.metaKey || event.ctrlKey;
  if (accel && (event.key === "s" || event.key === "S")) {
    event.preventDefault();
    save();
  } else if (accel && (event.key === "b" || event.key === "B")) {
    event.preventDefault();
    wrapSelection("strong");
  } else if (accel && (event.key === "i" || event.key === "I")) {
    event.preventDefault();
    wrapSelection("em");
  } else if (accel && (event.key === "u" || event.key === "U")) {
    event.preventDefault();
    wrapSelection("u");
  } else if (event.key === "Escape" && linkDialog.open) {
    linkDialog.close();
  }
});

const storedDoc = localStorage.getItem(DOC_KEY);
if (storedDoc !== null && storedDoc !== "") doc.innerHTML = storedDoc;
const storedTitle = localStorage.getItem(TITLE_KEY);
if (storedTitle !== null && storedTitle !== "") title.value = storedTitle;
lastSnapshot = doc.innerHTML;

updateCounts();
refresh();
