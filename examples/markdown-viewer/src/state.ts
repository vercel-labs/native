import { asciiBytes, utf8Bytes, markdownImageSources, imageSourceIdentity } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, caretSelectionAt, type TextInputEvent, type TextSelection, type TextRange } from "@native-sdk/core/text";
import type { Model, Msg } from "./core.ts";
import { sampleTable } from "./samples.ts";

export interface ViewerIdentity { readonly imageLower: number; readonly imageUpper: number; }
export interface ViewerImageCommand { readonly operation: "load" | "cancel" | "unregister"; readonly identity: ViewerIdentity; readonly path: Uint8Array; readonly url: Uint8Array; readonly cachePath: Uint8Array; readonly expectedBytes: number; }
export interface ViewerText { readonly text: Uint8Array; readonly selection: TextSelection; readonly composition: TextRange | null; readonly truncated: boolean; }
export interface RecentPath { readonly value: Uint8Array; }
export interface PreviewImage { readonly source: Uint8Array; readonly identity: ViewerIdentity; readonly width: number; readonly height: number; readonly loaded: boolean; }
export interface ViewerPlan {
  readonly model: Model;
  readonly read: Uint8Array; readonly write: Uint8Array;
  readonly persist: boolean; readonly restore: boolean;
  readonly images: readonly ViewerImageCommand[];
  readonly browser: Uint8Array | null;
}
export const documentCapacity = 16384;
export const pathCapacity = 512;
export const imageCapacity = 12;

export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
export function concat(parts: readonly Uint8Array[]): Uint8Array {
  let count = 0; for (const part of parts) count += part.length;
  const output = new Uint8Array(count); let at = 0;
  for (const part of parts) { output.set(part, at); at += part.length; }
  return output;
}
export function textSet(old: ViewerText, value: Uint8Array, capacity: number): ViewerText {
  const text = value.slice(0, Math.min(value.length, capacity));
  // TextBuffer.set preserves its previous truncation flag, even on short input.
  return { text, selection: caretSelectionAt(text.length, text.length), composition: null, truncated: old.truncated };
}
export function textEdit(old: ViewerText, edit: TextInputEvent, capacity: number): ViewerText {
  const next = applyTextInputEvent(old, edit, capacity);
  if (next !== null) return { text: next.text, selection: next.selection, composition: next.composition, truncated: false };
  const clamped = clampedInsertEvent(old, edit, capacity);
  const recovered = clamped === null ? null : applyTextInputEvent(old, clamped, capacity);
  return recovered === null ? { ...old, truncated: true } : { text: recovered.text, selection: recovered.selection, composition: recovered.composition, truncated: true };
}
export function blankText(): ViewerText { return { text: asciiBytes(""), selection: { anchor: 0, focus: 0 }, composition: null, truncated: false }; }
export function blankImage(): PreviewImage { return { source: asciiBytes(""), identity: { imageLower: 0, imageUpper: 0 }, width: 0, height: 0, loaded: false }; }
export function basename(value: Uint8Array, windows: boolean): Uint8Array {
  let separator = -1;
  for (let i = 0; i < value.length; i++) if (value[i] === (windows ? 92 : 47)) separator = i;
  return separator >= 0 && separator + 1 < value.length ? value.slice(separator + 1) : value;
}
export function title(model: Model): Uint8Array {
  for (const sample of sampleTable) if (sample.id === model.active_sample_id) return sample.title;
  return model.current_path.length > 0 ? basename(model.current_path, equal(model.target_os, asciiBytes("windows"))) : utf8Bytes("Untitled");
}
function note(model: Model, parts: readonly Uint8Array[]): Model {
  const value = concat(parts);
  return { ...model, note: value.length <= 192 ? value : asciiBytes("") };
}
export function sample(model: Model, id: number): Model {
  if (!(id >= 1 && id <= 4)) return model;
  for (const entry of sampleTable) if (entry.id === id) return { ...model, editor: textSet(model.editor, entry.body, documentCapacity), active_sample_id: Math.trunc(id), current_path: asciiBytes(""), details_expanded: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false], doc_scroll: 0, note: asciiBytes("") };
  return model;
}
export function pushRecent(model: Model, path: Uint8Array): Model {
  if (path.length === 0 || path.length > pathCapacity) return model;
  const recents: RecentPath[] = [{ value: path }];
  for (const entry of model.recents) {
    if (equal(entry.value, path)) continue;
    if (recents.length >= 6) break;
    recents.push({ value: entry.value });
  }
  return { ...model, recents };
}
function restoreRecent(model: Model, bytes: Uint8Array): Model {
  const recents: RecentPath[] = []; let start = 0;
  for (let at = 0; at <= bytes.length; at++) {
    if (at !== bytes.length && bytes[at] !== 10) continue;
    let first = start, end = at; start = at + 1;
    while (first < end && (bytes[first] === 32 || bytes[first] === 9 || bytes[first] === 13)) first++;
    while (end > first && (bytes[end - 1] === 32 || bytes[end - 1] === 9 || bytes[end - 1] === 13)) end--;
    if (end === first || end - first > pathCapacity) continue;
    recents.push({ value: bytes.slice(first, end) });
    // Restoration deliberately retains duplicate paths, as the reference does.
    if (recents.length >= 6) break;
  }
  return { ...model, recents };
}
export function serializeRecent(model: Model): Uint8Array {
  const parts: Uint8Array[] = [];
  for (const entry of model.recents) { parts.push(entry.value); parts.push(asciiBytes("\n")); }
  return concat(parts);
}
function idEqual(a: ViewerIdentity, b: ViewerIdentity): boolean { return a.imageLower === b.imageLower && a.imageUpper === b.imageUpper; }
function remote(source: Uint8Array): boolean {
  if (source.length === 0 || source.length > 2048) return false;
  const http = asciiBytes("http://"), https = asciiBytes("https://");
  let a = source.length >= http.length, b = source.length >= https.length;
  for (let i = 0; i < 8 && i < source.length; i++) {
    const raw = source[i], byte = raw >= 65 && raw <= 90 ? raw + 32 : raw;
    if (i < http.length && byte !== http[i]) a = false;
    if (byte !== https[i]) b = false;
  }
  return a || b;
}
function identity(images: readonly PreviewImage[], source: Uint8Array): ViewerIdentity {
  let id = imageSourceIdentity(source);
  for (;;) {
    let collision = false;
    for (const image of images) if (image.source.length > 0 && idEqual(image.identity, id) && !equal(image.source, source)) { collision = true; break; }
    if (!collision) return id;
    const lower = id.imageLower === 4294967295 ? 0 : id.imageLower + 1;
    const upper = id.imageLower === 4294967295 ? (id.imageUpper + 1) & 2147483647 : id.imageUpper;
    id = { imageLower: upper === 0 && lower <= 5 ? 16 : lower, imageUpper: upper };
  }
}
function imageCommand(operation: "load" | "cancel" | "unregister", id: ViewerIdentity, url: Uint8Array): ViewerImageCommand {
  return { operation, identity: id, path: asciiBytes(""), url, cachePath: asciiBytes(""), expectedBytes: 0 };
}
export function reconcile(model: Model): ViewerPlan {
  const discovered = markdownImageSources(model.editor.text, imageCapacity);
  const wanted = discovered.filter(item => remote(item.source));
  const images = model.preview_images.slice();
  const commands: ViewerImageCommand[] = [];
  for (let i = 0; i < images.length; i++) {
    const image = images[i]; if (image.source.length === 0) continue;
    let keep = false; for (const item of wanted) if (equal(item.source, image.source)) keep = true;
    if (keep) continue;
    commands.push(imageCommand("cancel", image.identity, asciiBytes("")));
    commands.push(imageCommand("unregister", image.identity, asciiBytes("")));
    images[i] = blankImage();
  }
  for (const item of wanted) {
    let present = false; for (const image of images) if (image.source.length > 0 && equal(image.source, item.source)) present = true;
    if (present) continue;
    let free = -1; for (let i = 0; i < images.length; i++) if (images[i].source.length === 0) { free = i; break; }
    if (free < 0) break;
    const id = identity(images, item.source);
    images[free] = { source: item.source, identity: id, width: 0, height: 0, loaded: false };
    commands.push(imageCommand("load", id, item.source));
  }
  return { ...quiet({ ...model, preview_images: images }), images: commands };
}
function quiet(model: Model): ViewerPlan { return { model, read: asciiBytes(""), write: asciiBytes(""), persist: false, restore: false, images: [], browser: null }; }
function trimSpaces(value: Uint8Array): Uint8Array {
  let first = 0, end = value.length;
  while (first < end && value[first] === 32) first++;
  while (end > first && value[end - 1] === 32) end--;
  return value.slice(first, end);
}
function openSave(model: Model, path: Uint8Array, save: boolean): ViewerPlan {
  if (path.length === 0) return quiet(model);
  const next = note({ ...model, pending_path: path.slice(0, pathCapacity) }, [save ? utf8Bytes("Saving ") : utf8Bytes("Opening "), basename(path, equal(model.target_os, asciiBytes("windows"))), utf8Bytes("…")]);
  return { ...quiet(next), read: save ? asciiBytes("") : next.pending_path, write: save ? next.pending_path : asciiBytes("") };
}
function adopt(model: Model): Model { return { ...model, current_path: model.pending_path, path_field: textSet(model.path_field, model.pending_path, pathCapacity) }; }

export function transition(model: Model, msg: Msg): ViewerPlan {
  switch (msg.kind) {
    case "edit": {
      const editor = textEdit(model.editor, msg.edit, documentCapacity);
      const next = { ...model, editor, active_sample_id: 0 };
      return reconcile(editor.truncated ? note(next, [utf8Bytes("Document is full (16 KiB cap)")]) : next);
    }
    case "edit_path": return quiet({ ...model, path_field: textEdit(model.path_field, msg.edit, pathCapacity) });
    case "load_sample": return reconcile({ ...sample(model, msg.id), sample_picker_open: false });
    case "toggle_sample_picker": return quiet({ ...model, sample_picker_open: !model.sample_picker_open });
    case "close_sample_picker": return quiet({ ...model, sample_picker_open: false });
    case "open_recent": {
      if (msg.index < 0 || msg.index >= model.recents.length) return quiet(model);
      const path = model.recents[msg.index].value;
      return openSave({ ...model, path_field: textSet(model.path_field, path, pathCapacity) }, path, false);
    }
    case "open_doc": return openSave(model, trimSpaces(model.path_field.text), false);
    case "save_doc": return openSave(model, model.current_path, true);
    case "save_as": return openSave(model, trimSpaces(model.path_field.text), true);
    case "appearance": return quiet({ ...model, system_scheme: msg.colorScheme });
    case "chrome_changed": return quiet({ ...model, chrome_leading: Math.fround(msg.insets.left), chrome_trailing: Math.fround(msg.insets.right), toolbar_height: Math.max(48, Math.fround(msg.insets.top)) });
    case "doc_scrolled": return quiet({ ...model, doc_scroll: Math.fround(msg.scroll.offsetY) });
    case "toggle_details": {
      const flags = model.details_expanded.slice();
      if (msg.index >= 0 && msg.index < flags.length) flags[msg.index] = !flags[msg.index];
      return quiet({ ...model, details_expanded: flags });
    }
    case "open_url": return { ...quiet(note(model, [utf8Bytes("Opening link…")])), browser: msg.url };
    case "file_done": {
      if (msg.operation === "read") {
        if (msg.outcome === "ok") {
          const next = pushRecent(adopt({ ...model, editor: textSet(model.editor, msg.bytes, documentCapacity), active_sample_id: 0, details_expanded: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false], doc_scroll: 0 }), model.pending_path);
          return { ...reconcile(note(next, [utf8Bytes("Opened "), title(next)])), persist: true };
        }
        if (msg.outcome === "truncated") return reconcile(note({ ...model, editor: textSet(model.editor, msg.bytes, documentCapacity), active_sample_id: 0, doc_scroll: 0 }, [utf8Bytes("Opened a cut copy: file exceeds the 16 KiB document cap")]));
        return quiet(note(model, [utf8Bytes("Open failed: "), asciiBytes(`${msg.outcome}`)]));
      }
      if (msg.operation === "write") {
        if (msg.outcome === "ok") {
          const next = pushRecent({ ...adopt(model), active_sample_id: 0 }, model.pending_path);
          return { ...quiet(note(next, [utf8Bytes("Saved "), title(next)])), persist: true };
        }
        return quiet(note(model, [utf8Bytes("Save failed: "), asciiBytes(`${msg.outcome}`)]));
      }
      return quiet(note(model, [utf8Bytes("Unexpected file operation: "), asciiBytes(`${msg.operation}`)]));
    }
    case "recent_done": return quiet(msg.operation === "read" && msg.outcome === "ok" ? restoreRecent(model, msg.bytes) : model);
    case "image_done": {
      const images = model.preview_images.slice(); let retained = false;
      const id: ViewerIdentity = { imageLower: msg.imageLower, imageUpper: msg.imageUpper };
      for (let i = 0; i < images.length; i++) {
        const image = images[i]; if (image.source.length === 0 || !idEqual(image.identity, id)) continue;
        retained = true;
        if (msg.state === "loaded" && msg.width > 0 && msg.height > 0) images[i] = { ...image, loaded: true, width: msg.width, height: msg.height };
        break;
      }
      return { ...quiet({ ...model, preview_images: images }), images: !retained && msg.state === "loaded" ? [imageCommand("unregister", id, asciiBytes(""))] : [] };
    }
    case "link_done": return quiet(note(model, [msg.reason === "exited" && msg.code === 0 ? utf8Bytes("Opened in browser") : concat([utf8Bytes("Browser open failed ("), asciiBytes(`${msg.reason}`), asciiBytes(")")])]));
    case "target_os": return quiet({ ...model, target_os: msg.os });
    case "app_data": {
      // Continue the example's existing short-name data directory.
      const windows = equal(model.target_os, asciiBytes("windows"));
      const path = concat([msg.path, windows ? asciiBytes("\\recent.txt") : asciiBytes("/recent.txt")]);
      if (msg.path.length === 0 || path.length > pathCapacity) return quiet(model);
      const next = { ...model, recent_path: path };
      return { ...quiet(next), restore: true };
    }
  }
}
