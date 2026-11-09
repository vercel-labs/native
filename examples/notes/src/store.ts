import { asciiBytes } from "@native-sdk/core";
import { parseStamp } from "./integer.ts";
import { type Folder, type Note, type Store, type TextBuffer, type NotesOverflow } from "./types.ts";
import { caretSelectionAt, type TextEditState } from "@native-sdk/core/text";
export function textState(text: Uint8Array, capacity: number): TextBuffer {
  let length = Math.min(text.length, capacity);
  const bytes = text.slice(0, length);
  return { text: bytes, selection: caretSelectionAt(length, length), composition: null, truncated: false };
}
export function concat(parts: readonly Uint8Array[]): Uint8Array {
  let size = 0; for (const part of parts) size += part.length;
  const out = new Uint8Array(size); let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) if (a[i] !== b[i]) return false;
  return true;
}
export function trim(text: Uint8Array, breaks: boolean): Uint8Array {
  let start = 0, end = text.length;
  while (start < end && (text[start] === 32 || breaks && (text[start] === 9 || text[start] === 13))) start += 1;
  while (end > start && (text[end - 1] === 32 || breaks && (text[end - 1] === 9 || text[end - 1] === 13))) end -= 1;
  return text.slice(start, end);
}
function numberToken(raw: Uint8Array, bound: number): number | null {
  let at = 0, value = 0;
  const negative = raw.length > 0 && raw[0] === 45;
  if (raw.length > 0 && (raw[0] === 43 || negative)) at = 1;
  if (at === raw.length || raw[at] === 95 || raw[raw.length - 1] === 95) return null;
  for (let i = at; i < raw.length; i += 1) {
    const byte = raw[i]; if (byte === 95) continue;
    if (byte < 48 || byte > 57 || negative && byte !== 48) return null;
    value = value * 10 + byte - 48; if (value > bound) return null;
  }
  return value;
}
function splitFields(line: Uint8Array): Uint8Array[] {
  const fields: Uint8Array[] = []; let start = 0;
  for (let i = 0; i <= line.length; i += 1) {
    if (i === line.length || line[i] === 32) { fields.push(line.slice(start, i)); start = i + 1; }
  }
  return fields;
}
export function serializeStore(model: Store): Uint8Array {
  const parts: Uint8Array[] = [asciiBytes("native-sdk-notes v2\n")];
  for (const folder of model.folders) parts.push(concat([asciiBytes(`folder ${folder.id} `), folder.name, asciiBytes("\n")]));
  for (const note of model.notes) parts.push(concat([asciiBytes(`note ${note.id} ${note.folder} `), note.created_ms, asciiBytes(" "), note.updated_ms, asciiBytes(" "), note.deleted_ms, asciiBytes(` ${note.body.text.length}\n`), note.body.text, asciiBytes("\n")]));
  return concat(parts);
}
export function restoreStore(bytes: Uint8Array): Store | null {
  let cursor = 0, headerEnd = 0;
  while (headerEnd < bytes.length && bytes[headerEnd] !== 10) headerEnd += 1;
  const header = bytes.slice(0, headerEnd), v1 = equal(header, asciiBytes("native-sdk-notes v1"));
  if (!v1 && !equal(header, asciiBytes("native-sdk-notes v2"))) return null;
  cursor = Math.min(bytes.length, headerEnd + 1);
  const folders: Folder[] = [], notes: Note[] = [];
  let next_folder_id = 1, next_note_id = 1;
  while (cursor < bytes.length) {
    let end = cursor; while (end < bytes.length && bytes[end] !== 10) end += 1;
    const line = bytes.slice(cursor, end); cursor = Math.min(bytes.length, end + 1);
    if (line.length === 0) continue;
    if (line.length >= 7 && equal(line.slice(0, 7), asciiBytes("folder "))) {
      if (folders.length >= 6) break;
      let nameAt = 7; while (nameAt < line.length && line[nameAt] !== 32) nameAt += 1;
      const id = numberToken(line.slice(7, nameAt), 4294967295);
      const name = trim(line.slice(Math.min(line.length, nameAt + 1)), false);
      if (id === null || !(id >= 1 && id <= 4294967295) || name.length === 0 || name.length > 32) break;
      if (id === 4294967295) throw { kind: "integer_overflow" } as NotesOverflow;
      const wholeId = Math.trunc(id);
      folders.push({ id: wholeId, name }); next_folder_id = Math.max(next_folder_id, wholeId + 1); continue;
    }
    if (line.length >= 5 && equal(line.slice(0, 5), asciiBytes("note "))) {
      if (notes.length >= 48) break;
      const fields = splitFields(line.slice(5));
      if (fields.length < (v1 ? 5 : 6)) break;
      const id = numberToken(fields[0], 4294967295), folder = numberToken(fields[1], 4294967295);
      const created_ms = parseStamp(fields[2]), updated_ms = parseStamp(fields[3]);
      const deleted_ms = v1 ? asciiBytes("0") : parseStamp(fields[4]);
      const length = numberToken(fields[v1 ? 4 : 5], 4096);
      if (id === null || !(id >= 1 && id <= 4294967295) || folder === null || !(folder >= 0 && folder <= 4294967295) || created_ms === null || updated_ms === null || deleted_ms === null || length === null || cursor + length > bytes.length) break;
      const body = textState(bytes.slice(cursor, cursor + length), 4096);
      if (id === 4294967295) throw { kind: "integer_overflow" } as NotesOverflow;
      const wholeId = Math.trunc(id);
      notes.push({ id: wholeId, folder: Math.trunc(folder), created_ms, updated_ms, deleted_ms, body });
      cursor += length; if (cursor < bytes.length && bytes[cursor] === 10) cursor += 1;
      next_note_id = Math.max(next_note_id, wholeId + 1); continue;
    }
    break;
  }
  if (folders.length === 0) return null;
  const recovered: Note[] = [];
  for (const note of notes) {
    if (note === undefined) continue;
    const home = folders.some((folder) => folder.id === note.folder) ? note.folder : folders[0].id;
    recovered.push({ id: note.id, folder: home, created_ms: note.created_ms, updated_ms: note.updated_ms, deleted_ms: note.deleted_ms, body: note.body });
  }
  return { folders, notes: recovered, next_folder_id, next_note_id };
}
