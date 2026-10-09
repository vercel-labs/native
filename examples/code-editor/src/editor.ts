import { entryIndex } from "./whole.ts";
import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import { bytesEqual, descendantSuffix, explorerRenamedPathsFit, explorerEntryOrder, assignExplorerParents, validExplorerName, renamedExplorerPath, joinPath, explorerItem, type DirectoryItem } from "./explorer.ts";
import { blankText, setText, blankDocument, editText, dirty, adoptDocument, previewCapacity } from "./document.ts";
import { contentHash } from "./content_hash.ts";
import { zeroCounter, initialFileKey, counterBytes, counterZero, incrementCounter, incrementFileKey } from "./counters.ts";
import type { BrowserState, EditorDocument, BrowserMsg, EditorPlan } from "./types.ts";

export function concat(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0; for (const part of parts) length += part.length;
  const output = new Uint8Array(length); let at = 0;
  for (const part of parts) { output.set(part, at); at += part.length; }
  return output;
}
export function status(browser: BrowserState, text: Uint8Array): BrowserState {
  return { ...browser, status: text.length <= 192 ? text : asciiBytes("") };
}
export function initialBrowser(index: number): BrowserState {
  return { root: asciiBytes(""), entries: [], tree_selected_entry: null, selected_entry: null,
    pinned_entries: [], preview_entry: null, hovered_tab: null, renaming_entry: null, pending_rename_entry: null,
    rename_buffer: blankText(), rename_truncated: false, rename_serial: zeroCounter(), pending_expand_entry: null,
    expand_serial: zeroCounter(), scan_truncated: false, scan_had_errors: false, sidebar_fraction: Math.fround(0.30),
    chrome_leading: 0, titlebar_height: 52, picker_serial: zeroCounter(), next_file_key: initialFileKey(index), documents: [], status: asciiBytes("") };
}
export function documentFor(browser: BrowserState, index: number | null): EditorDocument | null {
  if (index === null) return null;
  for (const document of browser.documents) if (document.entry_index === index) return document;
  return null;
}
export function activeDocument(browser: BrowserState): EditorDocument | null { return documentFor(browser, browser.selected_entry); }
export function hasWrites(browser: BrowserState): boolean { return browser.documents.some((document) => !counterZero(document.save_key)); }
export function hasDirty(browser: BrowserState): boolean { return browser.documents.some((document) => dirty(document)); }
function installDocument(browser: BrowserState, document: EditorDocument): BrowserState {
  return { ...browser, documents: browser.documents.map((old) => old.entry_index === document.entry_index ? document : old) };
}
export function isPinned(browser: BrowserState, index: number): boolean { return browser.pinned_entries.some((pinned) => pinned === index); }
export function openIndices(browser: BrowserState): number[] {
  const output: number[] = [];
  for (const raw of browser.pinned_entries) { const index = entryIndex(raw); if (browser.entries[index]?.kind === "file") output.push(index); }
  if (browser.preview_entry !== null && browser.entries[browser.preview_entry]?.kind === "file" && !isPinned(browser, browser.preview_entry)) output.push(browser.preview_entry);
  return output;
}
function isOpen(browser: BrowserState, index: number): boolean { return isPinned(browser, index) || browser.preview_entry === index; }
export function fullPath(browser: BrowserState, relative: Uint8Array): Uint8Array | null {
  if (browser.root.length === 0) return null;
  let end = browser.root.length;
  while (end > 0 && (browser.root[end - 1] === 47 || browser.root[end - 1] === 92)) end -= 1;
  const path = joinPath(browser.root.subarray(0, end), relative);
  return path.length > 1024 ? null : path;
}
export function stay(browser: BrowserState): EditorPlan {
  return { browser, read_path: asciiBytes(""), read_key: asciiBytes(""), write_path: asciiBytes(""), write_key: asciiBytes(""), write_bytes: asciiBytes(""), cancel_keys: [] };
}
function namedStatus(browser: BrowserState, first: Uint8Array, index: number, last: Uint8Array): BrowserState {
  return status(browser, concat([first, browser.entries[index]!.name, last]));
}
function closeUnchecked(plan: EditorPlan, index: number): EditorPlan {
  const browser = plan.browser, document = documentFor(browser, index);
  return { ...plan, browser: { ...browser, hovered_tab: browser.hovered_tab === index ? null : browser.hovered_tab,
    preview_entry: browser.preview_entry === index ? null : browser.preview_entry,
    pinned_entries: browser.pinned_entries.filter((pinned) => pinned !== index), documents: browser.documents.filter((document) => document.entry_index !== index) },
    cancel_keys: document === null || counterZero(document.read_key) ? plan.cancel_keys : plan.cancel_keys.concat([counterBytes(document.read_key)]) };
}
function activate(plan: EditorPlan, index: number): EditorPlan {
  const wholeIndex = index > 0 && index < 128 ? Math.trunc(index) : 0;
  let browser = plan.browser;
  const entry = browser.entries[index]; if (entry === undefined || entry.kind !== "file") return plan;
  browser = { ...browser, tree_selected_entry: wholeIndex, selected_entry: wholeIndex };
  let document = documentFor(browser, index);
  if (document === null) {
    if (browser.documents.length >= 17) return { ...plan, browser: status(browser, asciiBytes("Open document limit reached (17).")) };
    document = blankDocument(index); browser = { ...browser, documents: browser.documents.concat([document]) };
  }
  if (document.state === "text" || document.state === "binary" || document.state === "loading") return { ...plan, browser };
  const key = incrementFileKey(browser.next_file_key), path = fullPath(browser, entry.relative_path);
  const loading: EditorDocument = { ...document, state: path === null ? "failed" : "loading", editor: blankText(), source_truncated: false, read_key: path === null ? zeroCounter() : key };
  browser = installDocument({ ...browser, next_file_key: key }, loading);
  if (path === null) return { ...plan, browser: status(browser, asciiBytes("That file path is too long to read.")) };
  return { ...plan, browser: namedStatus(browser, asciiBytes("Opening "), index, utf8Bytes("…")), read_path: path, read_key: counterBytes(key) };
}
function preview(plan: EditorPlan, index: number): EditorPlan {
  const wholeIndex = index > 0 && index < 128 ? Math.trunc(index) : 0;
  let browser = plan.browser;
  if (browser.entries[index]?.kind !== "file") return plan;
  browser = { ...browser, tree_selected_entry: wholeIndex };
  if (!isPinned(browser, index)) {
    const previous = browser.preview_entry;
    if (previous !== null && previous !== index && !isPinned(browser, previous)) {
      const document = documentFor(browser, previous);
      if (document !== null) {
        if (!counterZero(document.save_key)) return { ...plan, browser: namedStatus(browser, asciiBytes("Wait for "), previous, asciiBytes(" to finish saving before replacing its preview tab.")) };
        if (dirty(document)) return { ...plan, browser: namedStatus(browser, asciiBytes("Save "), previous, asciiBytes(" before replacing its preview tab.")) };
      }
      plan = { ...plan, browser: { ...browser, documents: browser.documents.filter(document => document.entry_index !== previous) },
        cancel_keys: document === null || counterZero(document.read_key) ? plan.cancel_keys : plan.cancel_keys.concat([counterBytes(document.read_key)]) };
      browser = plan.browser;
    }
    browser = { ...browser, preview_entry: wholeIndex };
  }
  return activate({ ...plan, browser }, index);
}
function pin(plan: EditorPlan, index: number): EditorPlan {
  let browser = plan.browser;
  if (browser.entries[index]?.kind !== "file") return plan;
  if (!isPinned(browser, index)) {
    if (browser.pinned_entries.length === 16) return { ...plan, browser: status(browser, asciiBytes("Open tab limit reached (16).")) };
    browser = { ...browser, pinned_entries: browser.pinned_entries.concat([index]) };
  }
  if (browser.preview_entry === index) browser = { ...browser, preview_entry: null };
  return browser.selected_entry === index ? { ...plan, browser } : activate({ ...plan, browser }, index);
}
function close(plan: EditorPlan, index: number): EditorPlan {
  const browser = plan.browser;
  if (!isOpen(browser, index)) return plan;
  const document = documentFor(browser, index);
  if (document !== null) {
    if (!counterZero(document.save_key)) return { ...plan, browser: namedStatus(browser, asciiBytes("Wait for "), index, asciiBytes(" to finish saving before closing it.")) };
    if (dirty(document)) return { ...plan, browser: namedStatus(browser, asciiBytes("Save "), index, asciiBytes(" before closing it.")) };
  }
  const indices = openIndices(browser), position = indices.indexOf(index);
  const rawReplacement = position < 0 ? null : position + 1 < indices.length ? indices[position + 1]! : position > 0 ? indices[position - 1]! : null;
  const replacement = rawReplacement === null ? null : entryIndex(rawReplacement);
  let next = closeUnchecked(plan, index);
  if (browser.selected_entry === index) {
    next = { ...next, browser: { ...next.browser, selected_entry: null } };
    if (replacement !== null) next = activate(next, replacement);
  }
  return { ...next, browser: namedStatus(next.browser, asciiBytes("Closed "), index, asciiBytes(".")) };
}
function closeOthers(plan: EditorPlan, index: number): EditorPlan {
  if (!isOpen(plan.browser, index)) return plan;
  const open = openIndices(plan.browser);
  for (const raw of open) {
    const other = entryIndex(raw);
    if (other === index) continue;
    const document = documentFor(plan.browser, other); if (document === null) continue;
    if (!counterZero(document.save_key)) return { ...plan, browser: namedStatus(plan.browser, asciiBytes("Wait for "), other, asciiBytes(" to finish saving before closing other tabs.")) };
    if (dirty(document)) return { ...plan, browser: namedStatus(plan.browser, asciiBytes("Save "), other, asciiBytes(" before closing other tabs.")) };
  }
  let next = plan;
  for (const raw of open) { const other = entryIndex(raw); if (other !== index) next = closeUnchecked(next, other); }
  if (next.browser.selected_entry !== index) next = activate({ ...next, browser: { ...next.browser, selected_entry: null } }, index);
  return { ...next, browser: status(next.browser, asciiBytes("Closed other tabs.")) };
}
function startSave(plan: EditorPlan, index: number): EditorPlan {
  let browser = plan.browser;
  const entry = browser.entries[index], document = documentFor(browser, index);
  if (entry === undefined || document === null || document.state !== "text" || !dirty(document) || document.source_truncated || !counterZero(document.save_key)) return plan;
  const path = fullPath(browser, entry.relative_path);
  if (path === null) return { ...plan, browser: status(browser, asciiBytes("That file path is too long to save.")) };
  const rawLength = document.editor.text.length;
  const key = incrementFileKey(browser.next_file_key);
  browser = installDocument({ ...browser, next_file_key: key }, { ...document, save_key: key, pending_save_len: rawLength > 0 && rawLength <= 393216 ? Math.trunc(rawLength) : 0, pending_save_hash: contentHash(document.editor.text) });
  return { ...plan, browser: namedStatus(browser, asciiBytes("Saving "), index, utf8Bytes("…")), write_path: path, write_key: counterBytes(key), write_bytes: document.editor.text };
}
function fileDone(plan: EditorPlan, msg: BrowserMsg): EditorPlan {
  if (msg.kind !== "file_done") return plan;
  let browser = plan.browser;
  for (const document of browser.documents) {
    if (document === undefined) continue;
    const index = document.entry_index, entry = browser.entries[index]; if (entry === undefined) continue;
    if (msg.operation === "read" && bytesEqual(msg.key, counterBytes(document.read_key))) {
      let next: EditorDocument = { ...document, read_key: zeroCounter() };
      if (msg.outcome === "ok" || msg.outcome === "truncated") {
        next = adoptDocument(next, msg.bytes, msg.outcome === "truncated"); browser = installDocument(browser, next);
        const suffix = next.state === "binary" ? utf8Bytes(" · binary file") : next.source_truncated ? utf8Bytes(" · preview limited to 384 KiB") : utf8Bytes(` · ${next.editor.text.length} bytes`);
        browser = status(browser, concat([entry.relative_path, suffix]));
      } else {
        browser = installDocument(browser, { ...next, state: "failed" });
        browser = status(browser, concat([asciiBytes("Could not open "), entry.name, asciiBytes(": "), asciiBytes(`${msg.outcome}`)]));
      }
      return { ...plan, browser };
    }
    if (msg.operation === "write" && bytesEqual(msg.key, counterBytes(document.save_key))) {
      const next: EditorDocument = { ...document, save_key: zeroCounter(), save_queued: false,
        saved_len: msg.outcome === "ok" ? document.pending_save_len : document.saved_len,
        saved_hash: msg.outcome === "ok" ? document.pending_save_hash : document.saved_hash };
      browser = installDocument(browser, next);
      browser = status(browser, msg.outcome === "ok" ? concat([asciiBytes("Saved "), entry.relative_path, dirty(next) ? utf8Bytes(" · newer edits remain unsaved") : asciiBytes("")])
        : concat([asciiBytes("Could not save "), entry.name, asciiBytes(": "), asciiBytes(`${msg.outcome}`)]));
      const updated = { ...plan, browser };
      return document.save_queued && dirty(next) ? startSave(updated, index) : updated;
    }
  }
  return plan;
}
function touchesIo(browser: BrowserState, index: number): boolean {
  const renamed = browser.entries[index]!;
  for (const document of browser.documents) {
    const entry = browser.entries[document.entry_index]!;
    if (document.entry_index !== index && (renamed.kind !== "directory" || descendantSuffix(entry.relative_path, renamed.relative_path) === null)) continue;
    if (!counterZero(document.read_key) || !counterZero(document.save_key)) return true;
  }
  return false;
}
export function transition(browser: BrowserState, msg: BrowserMsg): EditorPlan {
  const plan = stay(browser);
  const rawIndex = msg.kind === "select_entry" || msg.kind === "preview_entry" || msg.kind === "pin_entry" || msg.kind === "begin_rename" || msg.kind === "activate_tab" || msg.kind === "hover_tab" || msg.kind === "unhover_tab" || msg.kind === "close_tab" || msg.kind === "close_other_tabs" || msg.kind === "toggle_entry" ? msg.index : 128;
  const wholeIndex = rawIndex > 0 && rawIndex < 128 ? Math.trunc(rawIndex) : 0;
  switch (msg.kind) {
    case "open_folder": return { ...plan, browser: hasWrites(browser) ? status(browser, asciiBytes("Wait for file saves before opening another folder."))
      : hasDirty(browser) ? status(browser, asciiBytes("Save all files before opening another folder.")) : { ...browser, picker_serial: incrementCounter(browser.picker_serial) } };
    case "select_entry": return { ...plan, browser: browser.entries[msg.index] === undefined ? browser : status({ ...browser, tree_selected_entry: wholeIndex }, browser.entries[msg.index]!.relative_path) };
    case "preview_entry": return preview(plan, msg.index);
    case "pin_entry": return pin(plan, msg.index);
    case "pin_tree_entry": return browser.tree_selected_entry === null ? plan : pin(plan, browser.tree_selected_entry);
    case "activate_tab": return isOpen(browser, msg.index) ? activate(plan, msg.index) : plan;
    case "hover_tab": return { ...plan, browser: isOpen(browser, msg.index) ? { ...browser, hovered_tab: wholeIndex } : browser };
    case "unhover_tab": return { ...plan, browser: browser.hovered_tab === msg.index ? { ...browser, hovered_tab: null } : browser };
    case "close_tab": return close(plan, msg.index);
    case "close_other_tabs": return closeOthers(plan, msg.index);
    case "close_active_tab": return browser.selected_entry === null ? plan : close(plan, browser.selected_entry);
    case "previous_tab": case "next_tab": {
      const indices = openIndices(browser); if (indices.length === 0) return plan;
      const at = browser.selected_entry === null ? -1 : indices.indexOf(browser.selected_entry);
      const next = at < 0 ? msg.kind === "next_tab" ? 0 : indices.length - 1 : msg.kind === "next_tab" ? (at + 1) % indices.length : at === 0 ? indices.length - 1 : at - 1;
      return browser.selected_entry === indices[next] ? plan : activate(plan, entryIndex(indices[next]!));
    }
    case "begin_rename": {
      const entry = browser.entries[msg.index];
      return entry === undefined ? plan : { ...plan, browser: status({ ...browser, tree_selected_entry: wholeIndex, renaming_entry: wholeIndex, pending_rename_entry: null, rename_buffer: setText(entry.name) }, concat([asciiBytes("Rename "), entry.relative_path])) };
    }
    case "edit_rename": {
      if (browser.renaming_entry === null || browser.pending_rename_entry !== null) return plan;
      const edited = editText(browser.rename_buffer, msg.edit, 255);
      const next = { ...browser, rename_buffer: edited.editor, rename_truncated: edited.truncated };
      return { ...plan, browser: edited.truncated ? status(next, asciiBytes("Names are limited to 255 bytes.")) : next };
    }
    case "commit_rename": {
      const index = browser.renaming_entry, name = browser.rename_buffer.text;
      if (index === null || browser.entries[index] === undefined || browser.pending_rename_entry !== null) return plan;
      const entry = browser.entries[index]!;
      if (!validExplorerName(name)) return { ...plan, browser: status(browser, asciiBytes("Enter a name without path separators.")) };
      if (bytesEqual(name, entry.name)) return { ...plan, browser: status({ ...browser, renaming_entry: null }, entry.relative_path) };
      if (!explorerRenamedPathsFit(browser.entries, index, name)) return { ...plan, browser: status(browser, asciiBytes("That renamed path is too long.")) };
      if (touchesIo(browser, index)) return { ...plan, browser: status(browser, asciiBytes("Wait for file activity to finish before renaming.")) };
      let serial = incrementCounter(browser.rename_serial); if (counterZero(serial)) serial = { counter_lower: 1, counter_upper: 0 };
      return { ...plan, browser: namedStatus({ ...browser, pending_rename_entry: index, rename_serial: serial }, asciiBytes("Renaming "), index, utf8Bytes("…")) };
    }
    case "toggle_entry": {
      const entry = browser.entries[msg.index]; if (entry === undefined || entry.kind !== "directory") return plan;
      if (entry.expanded || entry.children_loaded) return { ...plan, browser: { ...browser, entries: browser.entries.map((candidate, index) => candidate !== undefined && index === msg.index ? { ...candidate, expanded: !entry.expanded } : candidate) } };
      let serial = incrementCounter(browser.expand_serial); if (counterZero(serial)) serial = { counter_lower: 1, counter_upper: 0 };
      return { ...plan, browser: status({ ...browser, pending_expand_entry: wholeIndex, expand_serial: serial }, concat([asciiBytes("Loading "), entry.relative_path, utf8Bytes("…")])) };
    }
    case "edit_code": {
      const document = activeDocument(browser), index = browser.selected_entry;
      if (document === null || index === null) return plan;
      if (document.state !== "text" || document.source_truncated) return { ...plan, browser: document.source_truncated ? status(browser, asciiBytes("This cut preview is read-only to avoid overwriting the full file.")) : browser };
      const pinned = isPinned(browser, index) || browser.pinned_entries.length === 16 ? browser : { ...browser, pinned_entries: browser.pinned_entries.concat([index]), preview_entry: browser.preview_entry === index ? null : browser.preview_entry };
      const edited = editText(document.editor, msg.edit, previewCapacity), next = { ...document, editor: edited.editor, editor_truncated: edited.truncated };
      const updated = installDocument(pinned, next);
      return { ...plan, browser: status(updated, edited.truncated ? asciiBytes("File buffer is full (384 KiB cap).") : concat([browser.entries[index]!.relative_path, dirty(next) ? utf8Bytes(" · unsaved") : asciiBytes("")])) };
    }
    case "save_file": {
      const document = activeDocument(browser), index = browser.selected_entry;
      if (index === null || document === null || document.state !== "text" || !dirty(document)) return plan;
      if (document.source_truncated) return { ...plan, browser: status(browser, asciiBytes("Cannot save a cut preview; the full file was not loaded.")) };
      if (!counterZero(document.save_key)) return { ...plan, browser: namedStatus(installDocument(browser, { ...document, save_queued: true }), asciiBytes("Saving "), index, utf8Bytes("… latest edits queued")) };
      return startSave(plan, index);
    }
    case "file_done": return fileDone(plan, msg);
    case "sidebar_resized": return { ...plan, browser: { ...browser, sidebar_fraction: Math.fround(msg.fraction) } };
  }
}

/** One identity permutation updates every stored index together. */
export function sortAndRemap(browser: BrowserState): BrowserState {
  const sorted = browser.entries.map((entry, index) => entry !== undefined ? { ...entry, sort_identity: index > 0 && index < 128 ? Math.trunc(index) : 0 } : entry).toSorted(explorerEntryOrder);
  const mapping: number[] = []; for (let i = 0; i < sorted.length; i += 1) mapping.push(0);
  for (let i = 0; i < sorted.length; i += 1) mapping[sorted[i]!.sort_identity] = i;
  const mapped_tree_selected_entry = browser.tree_selected_entry === null ? 0 : mapping[browser.tree_selected_entry]!;
  const mapped_selected_entry = browser.selected_entry === null ? 0 : mapping[browser.selected_entry]!;
  const mapped_preview_entry = browser.preview_entry === null ? 0 : mapping[browser.preview_entry]!;
  const mapped_hovered_tab = browser.hovered_tab === null ? 0 : mapping[browser.hovered_tab]!;
  const mapped_pending_expand_entry = browser.pending_expand_entry === null ? 0 : mapping[browser.pending_expand_entry]!;
  return { ...browser, entries: assignExplorerParents(sorted.map((entry) => entry !== undefined ? { ...entry, sort_identity: 0 } : entry)),
    tree_selected_entry: browser.tree_selected_entry === null ? null : mapped_tree_selected_entry > 0 && mapped_tree_selected_entry < 128 ? Math.trunc(mapped_tree_selected_entry) : 0,
    selected_entry: browser.selected_entry === null ? null : mapped_selected_entry > 0 && mapped_selected_entry < 128 ? Math.trunc(mapped_selected_entry) : 0, preview_entry: browser.preview_entry === null ? null : mapped_preview_entry > 0 && mapped_preview_entry < 128 ? Math.trunc(mapped_preview_entry) : 0,
    hovered_tab: browser.hovered_tab === null ? null : mapped_hovered_tab > 0 && mapped_hovered_tab < 128 ? Math.trunc(mapped_hovered_tab) : 0, pending_expand_entry: browser.pending_expand_entry === null ? null : mapped_pending_expand_entry > 0 && mapped_pending_expand_entry < 128 ? Math.trunc(mapped_pending_expand_entry) : 0,
    pinned_entries: browser.pinned_entries.map((index) => entryIndex(mapping[entryIndex(index)]!)), documents: browser.documents.map((document) => {
      if (document === undefined) return document;
      const mapped = mapping[document.entry_index]!;
      return { ...document, entry_index: mapped > 0 && mapped < 128 ? Math.trunc(mapped) : 0 };
    }) };
}
export function scanDirectory(browser: BrowserState, root: Uint8Array, items: readonly DirectoryItem[], capped: boolean, errors: boolean): BrowserState {
  const initial = initialBrowser(0);
  const next = { ...initial, root, sidebar_fraction: browser.sidebar_fraction, chrome_leading: browser.chrome_leading, titlebar_height: browser.titlebar_height,
    picker_serial: browser.picker_serial, rename_serial: browser.rename_serial, expand_serial: browser.expand_serial, next_file_key: browser.next_file_key };
  return installDirectory(next, null, items, capped, errors);
}
export function installDirectory(browser: BrowserState, parentIndex: number | null, items: readonly DirectoryItem[], capped: boolean, errors: boolean): BrowserState {
  const parent = parentIndex === null ? null : browser.entries[parentIndex]!;
  const entries = browser.entries.slice(); let truncated = browser.scan_truncated || capped, hadErrors = browser.scan_had_errors || errors;
  for (const item of items) {
    if (entries.length === 128) { truncated = true; break; }
    const entry = explorerItem(item, parent); if (entry === null) hadErrors = true; else entries.push(entry);
  }
  const loaded = parentIndex === null ? entries : entries.map((entry, index) => entry !== undefined && index === parentIndex ? { ...entry, children_loaded: true, expanded: true } : entry);
  const sorted = sortAndRemap({ ...browser, entries: loaded, scan_truncated: truncated, scan_had_errors: hadErrors });
  return status(sorted, concat([asciiBytes(`${sorted.entries.length}`), parentIndex === null ? asciiBytes(" root items") : asciiBytes(" indexed items"),
    truncated ? utf8Bytes(" · tree capped") : asciiBytes(""), hadErrors ? utf8Bytes(" · some folders unavailable") : asciiBytes("")]));
}
export function finishRename(browser: BrowserState, error: Uint8Array): BrowserState {
  const index = browser.pending_rename_entry;
  const next: BrowserState = { ...browser, pending_rename_entry: null };
  if (index === null || browser.entries[index] === undefined) return next;
  const old = browser.entries[index]!, name = browser.rename_buffer.text;
  if (error.length > 0) return status(next, bytesEqual(error, asciiBytes("PathAlreadyExists")) ? concat([asciiBytes("An item named "), name, asciiBytes(" already exists.")]) : concat([asciiBytes("Could not rename "), old.name, asciiBytes(": "), error]));
  const path = renamedExplorerPath(old, name);
  const entries = browser.entries.map((entry, at) => {
    if (entry === undefined) return entry;
    if (at === index) return { ...entry, name, relative_path: path };
    const suffix = old.kind === "directory" ? descendantSuffix(entry.relative_path, old.relative_path) : null;
    return suffix === null ? entry : { ...entry, relative_path: joinPath(path, suffix) };
  });
  return status(sortAndRemap({ ...next, entries, renaming_entry: null }), concat([asciiBytes("Renamed "), old.name, asciiBytes(" to "), name, asciiBytes(".")]));
}
