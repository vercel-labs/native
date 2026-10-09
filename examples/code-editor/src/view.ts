import { entryIndex } from "./whole.ts";
import { asciiBytes } from "@native-sdk/core";
import { basename, explorerEntryVisible, bytesEqual } from "./explorer.ts";
import { activeDocument, documentFor, isPinned, openIndices } from "./editor.ts";
import { dirty } from "./document.ts";
import type { BrowserState, DocumentState } from "./types.ts";
export interface VisibleEntry {
  readonly index: number; readonly relative_path: Uint8Array; readonly name: Uint8Array; readonly tree_level: number;
  readonly indent: number; readonly icon: Uint8Array; readonly directory: boolean; readonly expanded: boolean; readonly selected: boolean; readonly renaming: boolean;
}
export interface OpenTab {
  readonly index: number; readonly relative_path: Uint8Array; readonly name: Uint8Array;
  readonly preview: boolean; readonly selected: boolean; readonly dirty: boolean; readonly show_close: boolean; readonly only_tab: boolean;
}
export type EditorLanguage = "plain" | "zig" | "javascript" | "typescript" | "jsx" | "tsx" | "python" | "json" | "yaml" | "shell" | "rust" | "c_like" | "go" | "html" | "css" | "sql" | "markdown";
export interface EditorPage {
  readonly index: number; readonly sidebar_fraction: number; readonly titlebar_height: number; readonly chrome_leading: number;
  readonly rootName: Uint8Array; readonly folderOpen: boolean; readonly status: Uint8Array; readonly renameText: Uint8Array;
  readonly preview: Uint8Array; readonly previewState: DocumentState;
  readonly previewTruncated: boolean; readonly codeEditable: boolean; readonly saveDisabled: boolean;
  readonly selectedIsFile: boolean; readonly selectedPath: Uint8Array; readonly emptyEditorTitle: Uint8Array; readonly emptyEditorDetail: Uint8Array;
  readonly previewLanguage: EditorLanguage; readonly visible: readonly VisibleEntry[]; readonly openTabs: readonly OpenTab[];
}
function extension(path: Uint8Array): Uint8Array {
  let at = -1; for (let i = 0; i < path.length; i += 1) { if (path[i] === 47) at = -1; if (path[i] === 46) at = i; }
  if (at < 0) return asciiBytes("");
  const result = path.slice(at + 1); for (let i = 0; i < result.length; i += 1) if (result[i]! >= 65 && result[i]! <= 90) result[i] = result[i]! + 32;
  return result;
}
export function language(path: Uint8Array): EditorLanguage {
  const name = extension(path);
  // Byte text equality is explicit under both Node and the compiled core.
  if (bytesEqual(name, asciiBytes("zon"))) return "zig";
  if (bytesEqual(name, asciiBytes("native"))) return "html";
  if (bytesEqual(name, asciiBytes("zig"))) return "zig";
  if (bytesEqual(name, asciiBytes("js")) || bytesEqual(name, asciiBytes("mjs")) || bytesEqual(name, asciiBytes("javascript"))) return "javascript";
  if (bytesEqual(name, asciiBytes("ts")) || bytesEqual(name, asciiBytes("typescript"))) return "typescript";
  if (bytesEqual(name, asciiBytes("jsx"))) return "jsx";
  if (bytesEqual(name, asciiBytes("tsx"))) return "tsx";
  if (bytesEqual(name, asciiBytes("json")) || bytesEqual(name, asciiBytes("jsonc"))) return "json";
  if (bytesEqual(name, asciiBytes("yaml")) || bytesEqual(name, asciiBytes("yml"))) return "yaml";
  if (bytesEqual(name, asciiBytes("sh")) || bytesEqual(name, asciiBytes("bash")) || bytesEqual(name, asciiBytes("zsh")) || bytesEqual(name, asciiBytes("shell"))) return "shell";
  if (bytesEqual(name, asciiBytes("py")) || bytesEqual(name, asciiBytes("python"))) return "python";
  if (bytesEqual(name, asciiBytes("rs")) || bytesEqual(name, asciiBytes("rust"))) return "rust";
  if (bytesEqual(name, asciiBytes("c")) || bytesEqual(name, asciiBytes("h")) || bytesEqual(name, asciiBytes("cc")) || bytesEqual(name, asciiBytes("cpp")) || bytesEqual(name, asciiBytes("c++")) || bytesEqual(name, asciiBytes("cs")) || bytesEqual(name, asciiBytes("csharp")) || bytesEqual(name, asciiBytes("java")) || bytesEqual(name, asciiBytes("kotlin")) || bytesEqual(name, asciiBytes("swift"))) return "c_like";
  if (bytesEqual(name, asciiBytes("go")) || bytesEqual(name, asciiBytes("golang"))) return "go";
  if (bytesEqual(name, asciiBytes("html")) || bytesEqual(name, asciiBytes("xml")) || bytesEqual(name, asciiBytes("svg"))) return "html";
  if (bytesEqual(name, asciiBytes("css")) || bytesEqual(name, asciiBytes("scss")) || bytesEqual(name, asciiBytes("less"))) return "css";
  if (bytesEqual(name, asciiBytes("sql"))) return "sql";
  if (bytesEqual(name, asciiBytes("md")) || bytesEqual(name, asciiBytes("markdown"))) return "markdown";
  return "plain";
}
export function project(browser: BrowserState, index: number): EditorPage {
  const selected = browser.selected_entry === null ? null : browser.entries[browser.selected_entry] ?? null;
  const document = activeDocument(browser), indices = openIndices(browser), openTabs: OpenTab[] = [], visible: VisibleEntry[] = [];
  for (const raw of indices) {
    const index = entryIndex(raw);
    const entry = browser.entries[index]!, tabDocument = documentFor(browser, index), active = browser.selected_entry === index;
    openTabs.push({ index: index > 0 && index < 128 ? Math.trunc(index) : 0, relative_path: entry.relative_path, name: entry.name, preview: browser.preview_entry === index && !isPinned(browser, index),
      selected: active, dirty: tabDocument !== null && dirty(tabDocument), show_close: active || browser.hovered_tab === index, only_tab: indices.length === 1 });
  }
  for (let at = 0; at < browser.entries.length; at += 1) {
    const entry = browser.entries[at]!; if (!explorerEntryVisible(browser.entries, entry)) continue;
    const indent = 4 + Math.max(0, entry.depth - 1) * 16;
    visible.push({ index: at > 0 && at < 128 ? Math.trunc(at) : 0, relative_path: entry.relative_path, name: entry.name, tree_level: entry.depth, indent: indent > 0 && indent <= 4068 ? Math.trunc(indent) : 4,
      icon: entry.kind === "directory" ? entry.expanded ? asciiBytes("folder-open") : asciiBytes("folder") : asciiBytes("file-text"),
      directory: entry.kind === "directory", expanded: entry.expanded, selected: browser.tree_selected_entry === at, renaming: browser.renaming_entry === at });
  }
  const selectedPath = selected === null ? asciiBytes("") : selected.relative_path;
  return { index: index > 0 && index < 5 ? Math.trunc(index) : 0, sidebar_fraction: browser.sidebar_fraction, titlebar_height: browser.titlebar_height, chrome_leading: browser.chrome_leading,
    rootName: browser.root.length === 0 ? asciiBytes("Code Explorer") : basename(browser.root), folderOpen: browser.root.length > 0, status: browser.status, renameText: browser.rename_buffer.text,
    preview: document === null ? asciiBytes("") : document.editor.text, previewState: document === null ? "idle" : document.state,
    previewTruncated: document !== null && document.source_truncated, codeEditable: document !== null && document.state === "text" && !document.source_truncated,
    saveDisabled: document === null || document.state !== "text" || !dirty(document) || document.source_truncated, selectedIsFile: selected !== null && selected.kind === "file", selectedPath,
    emptyEditorTitle: selected !== null && selected.kind === "directory" ? selected.name : asciiBytes("Select a file"),
    emptyEditorDetail: selected !== null && selected.kind === "directory" ? asciiBytes("This is a folder. Expand it or select a file.") : asciiBytes("Choose a file from the tree to preview its source."),
    previewLanguage: language(selectedPath), visible, openTabs };
}
