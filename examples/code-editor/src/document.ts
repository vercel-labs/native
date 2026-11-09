import { entryIndex } from "./whole.ts";
import { asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, caretSelectionAt, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";
import { contentHash, type ContentHash } from "./content_hash.ts";
import { zeroCounter } from "./counters.ts";
import type { EditorDocument } from "./types.ts";

export const previewCapacity = 393216;
export interface EditorText { readonly editor: TextEditState; readonly truncated: boolean; }
export function blankText(): TextEditState {
  return { text: asciiBytes(""), selection: { anchor: 0, focus: 0 }, composition: null };
}
export function setText(text: Uint8Array): TextEditState {
  return { text, selection: caretSelectionAt(text.length, text.length), composition: null };
}
export function editText(editor: TextEditState, event: TextInputEvent, capacity: number): EditorText {
  const next = applyTextInputEvent(editor, event, capacity);
  if (next !== null) return { editor: next, truncated: false };
  const clamped = clampedInsertEvent(editor, event, capacity);
  const recovered = clamped === null ? null : applyTextInputEvent(editor, clamped, capacity);
  return { editor: recovered === null ? editor : recovered, truncated: true };
}
export function hashEqual(a: ContentHash, b: ContentHash): boolean {
  return a.hash_lower === b.hash_lower && a.hash_upper === b.hash_upper;
}
export function dirty(document: EditorDocument): boolean {
  return document.state === "text" && (document.editor.text.length !== document.saved_len || !hashEqual(contentHash(document.editor.text), document.saved_hash));
}
export function blankDocument(index: number): EditorDocument {
  return { entry_index: index > 0 && index < 128 ? Math.trunc(index) : 0, editor: blankText(), editor_truncated: false, state: "idle", source_truncated: false,
    read_key: zeroCounter(), save_key: zeroCounter(), save_queued: false, saved_len: 0,
    saved_hash: { hash_lower: 0, hash_upper: 0 }, pending_save_len: 0, pending_save_hash: { hash_lower: 0, hash_upper: 0 } };
}
/** Strict UTF-8 validation; only a provably incomplete final scalar is repairable. */
export function validatedPrefix(bytes: Uint8Array, truncated: boolean): number | null {
  let at = 0;
  while (at < bytes.length) {
    const first = bytes[at]!;
    if (first === 0) return null;
    if (first < 128) { at += 1; continue; }
    const length = first >= 194 && first <= 223 ? 2 : first >= 224 && first <= 239 ? 3 : first >= 240 && first <= 244 ? 4 : 0;
    if (length === 0) return null;
    const end = Math.min(bytes.length, at + length);
    for (let i = at + 1; i < end; i += 1) if ((bytes[i]! & 192) !== 128) return null;
    if (at + 1 < end) {
      const second = bytes[at + 1]!;
      if (first === 224 && second < 160 || first === 237 && second > 159 || first === 240 && second < 144 || first === 244 && second > 143) return null;
    }
    if (at + length > bytes.length) return truncated ? at : null;
    at += length;
  }
  return at;
}
export function adoptDocument(document: EditorDocument, bytes: Uint8Array, truncated: boolean): EditorDocument {
  // NUL anywhere, including beyond the display cap, selects the binary state.
  for (const byte of bytes) if (byte === 0) return binaryDocument(document);
  const prefix = validatedPrefix(bytes, truncated);
  if (prefix === null) return binaryDocument(document);
  let end = Math.min(prefix, previewCapacity);
  while (end > 0 && end < prefix && (bytes[end]! & 192) === 128) end -= 1;
  const text = bytes.slice(0, end);
  return { ...document, editor: setText(text), state: "text", source_truncated: truncated || end < prefix,
    saved_len: end > 0 && end <= 393216 ? Math.trunc(end) : 0, saved_hash: contentHash(text) };
}
function binaryDocument(document: EditorDocument): EditorDocument {
  return { ...document, editor: blankText(), state: "binary", source_truncated: false,
    saved_len: 0, saved_hash: { hash_lower: 0, hash_upper: 0 } };
}
