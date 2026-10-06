export type TimerOutcome = "fired" | "rejected";
export type ClipboardOutcome = "ok" | "failed" | "rejected" | "cancelled";
export type ClipboardOp = "read" | "write";
export type FileOutcome = "ok" | "not_found" | "io_failed" | "truncated" | "rejected" | "cancelled" | "sink_missing" | "out_of_order" | "disk_full";
export type FileEvent = "terminal" | "chunk" | "done";
export type FileOperation = "read" | "write" | "append" | "stat" | "read_stream" | "write_stream_open" | "write_stream_chunk" | "write_stream_close" | "delete";
import { Cmd, asciiBytes, utf8Bytes, type EnvMsg } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, containsIgnoreCase, orderIgnoreCase, type TextInputEvent, type TextEditState } from "@native-sdk/core/text";
import { type ChromeInsets, type ChromeButtons, type ColorScheme, type ThemeState, type ScrollState } from "@native-sdk/core/events";
import { type ThemeDesignTokenOverrides } from "@native-sdk/core/theme";
import { type Folder, type Note, type TextBuffer, type NotesOverflow } from "./types.ts";
import { concat, equal, trim, textState, serializeStore, restoreStore } from "./store.ts";
import { compareMagnitude, compareStamp, subtractStamp, divideMagnitude } from "./integer.ts";
import { notesColors } from "./theme.ts";

export type DialogMode = "closed" | "create_folder" | "rename_folder";
type EffectIntent = "none" | "persist" | "clock" | "save_timer" | "copy" | "boot";
export type ClockAction = { readonly kind: "idle" } | { readonly kind: "stamp_edit"; readonly edited_note_id: number }
  | { readonly kind: "new_note" } | { readonly kind: "trash"; readonly id: number }
  | { readonly kind: "restore"; readonly id: number } | { readonly kind: "delete_folder"; readonly id: number } | { readonly kind: "refresh" };
export interface Model {
  readonly folders: readonly Folder[]; readonly notes: readonly Note[];
  readonly next_folder_id: number; readonly next_note_id: number;
  readonly selected_folder: number; readonly active_note: number;
  readonly search_buffer: TextBuffer; readonly folder_field: TextBuffer;
  readonly dialog: DialogMode;
  readonly dialog_folder: number; readonly dialog_hint: Uint8Array;
  readonly store_path: Uint8Array; readonly store_write_inflight: boolean; readonly save_pending: boolean;
  readonly system_scheme: ColorScheme; readonly now_ms: Uint8Array; readonly activity: Uint8Array;
  readonly sidebar_split: number; readonly list_split: number; readonly note_list_scroll: number;
  readonly hovered_note: number; readonly chrome_leading: number; readonly header_height: number;
  readonly pending_clock: ClockAction;
}
export type Msg =
  | { readonly kind: "edit"; readonly event: TextInputEvent }
  | { readonly kind: "search_edit"; readonly event: TextInputEvent }
  | { readonly kind: "folder_field_edit"; readonly event: TextInputEvent }
  | { readonly kind: "select_folder"; readonly id: number } | { readonly kind: "select_folder_at"; readonly position: Uint8Array }
  | { readonly kind: "select_trash" } | { readonly kind: "open_note"; readonly id: number }
  | { readonly kind: "hover_note"; readonly id: number } | { readonly kind: "unhover_note"; readonly id: number }
  | { readonly kind: "next_note" } | { readonly kind: "prev_note" } | { readonly kind: "new_note" }
  | { readonly kind: "delete_note" } | { readonly kind: "copy_note" } | { readonly kind: "copy_note_id"; readonly id: number }
  | { readonly kind: "trash_note"; readonly id: number } | { readonly kind: "restore_note"; readonly id: number } | { readonly kind: "purge_note"; readonly id: number }
  | { readonly kind: "open_create_folder" } | { readonly kind: "open_rename_folder" }
  | { readonly kind: "rename_folder"; readonly id: number } | { readonly kind: "delete_folder"; readonly id: number }
  | { readonly kind: "confirm_dialog" } | { readonly kind: "close_dialog" } | { readonly kind: "dismiss" }
  | { readonly kind: "sidebar_resized"; readonly fraction: number } | { readonly kind: "list_resized"; readonly fraction: number }
  | { readonly kind: "note_list_scrolled"; readonly state: ScrollState }
  | { readonly kind: "system_scheme"; readonly colorScheme: ColorScheme;
  readonly reduceMotion: boolean;
  readonly highContrast: boolean; } | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets;
  readonly buttons: ChromeButtons;
  readonly tabsProjected: boolean; }
  | { readonly kind: "refresh_tick"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: TimerOutcome; } | { readonly kind: "save_tick"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: TimerOutcome; }
  | { readonly kind: "store_done"; readonly key: Uint8Array; readonly operation: FileOperation; readonly event: FileEvent;
  readonly outcome: FileOutcome; readonly bytes: Uint8Array; readonly totalBytes: Uint8Array;
  readonly mtimeMs: Uint8Array; readonly exists: boolean; readonly droppedBefore: number; } | { readonly kind: "clipboard_done"; readonly key: Uint8Array;
  readonly operation: ClipboardOp;
  readonly outcome: ClipboardOutcome;
  readonly text: Uint8Array;
  readonly droppedBefore: number; }
  | { readonly kind: "data_dir_set"; readonly value: Uint8Array }
  | { readonly kind: "seed_clock"; readonly stamp: Uint8Array } | { readonly kind: "clock_done"; readonly stamp: Uint8Array };
export const envMsgs: readonly EnvMsg<Msg>[] = [{ env: "NATIVE_SDK_APP_LEGACY_DATA_DIR", msg: "data_dir_set" }];
export const appearanceMsg = "system_scheme";
export const chromeMsg = "chrome_changed";
export const viewUnbound = ["folders", "notes", "next_folder_id", "next_note_id", "selected_folder", "search_buffer", "folder_field", "dialog", "dialog_folder", "store_path", "store_write_inflight", "save_pending", "system_scheme", "now_ms", "activity", "hovered_note", "pending_clock", "select_folder_at", "next_note", "prev_note", "delete_note", "copy_note", "open_rename_folder", "dismiss", "system_scheme", "chrome_changed", "refresh_tick", "save_tick", "store_done", "clipboard_done", "data_dir_set", "seed_clock", "clock_done", "tokenOverrides"] as const;
const TRASH = 4294967295;
const ZERO = asciiBytes("0");
function deleted(note: Note): boolean { return !equal(note.deleted_ms, ZERO); }
function blank(): TextBuffer { return textState(asciiBytes(""), 0); }
function noteById(model: Model, id: number): Note | null { return model.notes.find((note) => note.id === id) ?? null; }
function folderById(model: Model, id: number): Folder | null { return model.folders.find((folder) => folder.id === id) ?? null; }
function active(model: Model): Note | null { return noteById(model, model.active_note); }
function visible(model: Model): Note[] {
  return model.notes.filter((note) => deleted(note) === (model.selected_folder === TRASH)
    && (model.selected_folder === TRASH || model.selected_folder === 0 || note.folder === model.selected_folder)
    && containsIgnoreCase(note.body.text, model.search_buffer.text))
    .toSorted((a, b) => { const order = compareStamp(a.updated_ms, b.updated_ms); return order === 0 ? b.id - a.id : -order; });
}
function selectTop(model: Model): Model { const rows = visible(model); return { ...model, active_note: rows.length === 0 ? 0 : rows[0].id }; }
function selectFolder(model: Model, id: number): Model {
  if (!(id >= 0 && id <= 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
  id = Math.trunc(id);
  if (id !== 0 && folderById(model, id) === null) return model;
  return selectTop({ ...model, selected_folder: id, note_list_scroll: 0 });
}
function leaveEmptyTrash(model: Model): Model {
  return model.selected_folder === TRASH && !model.notes.some(deleted) ? { ...model, selected_folder: 0 } : model;
}
function editing(state: TextBuffer, event: TextInputEvent, capacity: number): TextBuffer {
  const next = applyTextInputEvent(state, event, capacity); if (next !== null) return { ...next, truncated: false };
  const clamped = clampedInsertEvent(state, event, capacity);
  const recovery = clamped === null ? state : applyTextInputEvent(state, clamped, capacity) ?? state;
  return { ...recovery, truncated: true };
}

interface Step { readonly model: Model; readonly effect: EffectIntent; readonly clipboard: Uint8Array; }
function stay(model: Model): Step { return { model, effect: "none", clipboard: asciiBytes("") }; }
function persist(model: Model): Step {
  if (model.store_path.length === 0) return stay(model);
  if (model.store_write_inflight) return stay({ ...model, save_pending: true });
  return { model: { ...model, store_write_inflight: true }, effect: "persist", clipboard: asciiBytes("") };
}
function clock(model: Model, action: ClockAction): Step {
  return { model: { ...model, pending_clock: action }, effect: "clock", clipboard: asciiBytes("") };
}
function newNote(model: Model): Step {
  const folder = model.selected_folder === 0 || model.selected_folder === TRASH ? model.folders[0].id : model.selected_folder;
  if (model.notes.length >= 48) return stay({ ...model, activity: asciiBytes("Note limit reached (48)") });
  const note: Note = { id: model.next_note_id, folder, created_ms: model.now_ms, updated_ms: model.now_ms, deleted_ms: ZERO, body: blank() };
  const home = folderById(model, folder); if (home === null) return stay(model);
  if (!(model.next_note_id >= 0 && model.next_note_id < 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
  return persist({ ...model, notes: [...model.notes, note], next_note_id: model.next_note_id >= 0 && model.next_note_id < 4294967295 ? Math.trunc(model.next_note_id) + 1 : 0,
    selected_folder: model.selected_folder === TRASH ? folder : model.selected_folder, search_buffer: blank(), active_note: note.id,
    activity: concat([asciiBytes("New note in "), home.name]) });
}
function trashNote(model: Model, id: number): Step {
  const note = noteById(model, id); if (note === null || deleted(note)) return stay(model);
  const changed = { ...model, notes: model.notes.map((n, index) => n !== undefined && index === model.notes.findIndex((n) => n.id === id) ? { ...n, deleted_ms: model.now_ms } : n),
    activity: concat([utf8Bytes('Moved "'), displayTitle(note.body.text), utf8Bytes('" to Recently Deleted')]) };
  return persist(model.active_note === id ? selectTop(changed) : changed);
}
function restoreNote(model: Model, id: number): Step {
  const note = noteById(model, id); if (note === null || !deleted(note)) return stay(model);
  const home = folderById(model, note.folder) === null && model.folders.length > 0 ? model.folders[0].id : note.folder;
  if (!(home >= 0 && home <= 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
  const notes: Note[] = [];
  let restored = false;
  for (const n of model.notes) {
    if (n === undefined) continue;
    if (!restored && n.id === id) {
      restored = true;
      notes.push({ id: n.id, folder: home >= 0 && home <= 4294967295 ? Math.trunc(home) : 0, created_ms: n.created_ms, updated_ms: n.updated_ms, deleted_ms: ZERO, body: n.body });
    } else notes.push(n);
  }
  const changed = leaveEmptyTrash({ ...model, notes,
    activity: concat([asciiBytes('Restored "'), displayTitle(note.body.text), asciiBytes('"')]) });
  return persist(model.active_note === id && changed.selected_folder === TRASH ? selectTop(changed) : changed);
}
function purgeNote(model: Model, id: number): Step {
  const note = noteById(model, id); if (note === null || !deleted(note)) return stay(model);
  const changed = leaveEmptyTrash({ ...model, notes: model.notes.filter((n, index) => index !== model.notes.findIndex((n) => n.id === id)),
    activity: concat([asciiBytes('Deleted "'), displayTitle(note.body.text), asciiBytes('" permanently')]) });
  return persist(model.active_note === id ? selectTop(changed) : changed);
}
function deleteFolder(model: Model, id: number): Step {
  const folder = folderById(model, id); if (folder === null) return stay(model);
  if (model.folders.length <= 1) return stay({ ...model, activity: asciiBytes("Keep at least one folder") });
  const moved = model.notes.filter((note) => note.folder === id && !deleted(note)).length;
  const next = { ...model, folders: model.folders.filter((f, index) => index !== model.folders.findIndex((f) => f.id === id)), selected_folder: model.selected_folder === id ? 0 : model.selected_folder,
    notes: model.notes.map((note) => note.folder === id && !deleted(note) ? { ...note, deleted_ms: model.now_ms } : note),
    activity: concat([asciiBytes('Deleted folder "'), folder.name, asciiBytes('"'), moved === 0 ? asciiBytes("") : utf8Bytes(` · ${moved} note${moved === 1 ? "" : "s"} to Recently Deleted`)]) };
  const opened = active(next);
  return persist(opened === null || deleted(opened) && next.selected_folder !== TRASH ? selectTop(next) : next);
}
function renameDialog(model: Model, id: number, missing: Uint8Array): Model {
  const folder = folderById(model, id); if (folder === null) return { ...model, activity: missing };
  if (!(id >= 0 && id <= 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
  return { ...model, dialog: "rename_folder", dialog_folder: Math.trunc(id), folder_field: { ...textState(folder.name, 32), truncated: model.folder_field.truncated }, dialog_hint: asciiBytes("") };
}
function confirmDialog(model: Model): Step {
  if (model.dialog === "closed") return stay(model);
  const raw = model.folder_field.text, clean = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) clean[i] = raw[i] === 10 || raw[i] === 13 || raw[i] === 9 ? 32 : raw[i];
  const candidate = trim(clean, false);
  if (candidate.length === 0) return stay({ ...model, dialog_hint: asciiBytes("A folder needs a name.") });
  const ignored = model.dialog === "rename_folder" ? model.dialog_folder : 0;
  if (model.folders.some((folder) => folder.id !== ignored && orderIgnoreCase(folder.name, candidate) === 0))
    return stay({ ...model, dialog_hint: asciiBytes("That name is already taken.") });
  if (model.dialog === "create_folder") {
    if (model.folders.length >= 6) return stay({ ...model, dialog: "closed", activity: asciiBytes("Folder limit reached (6)") });
    if (!(model.next_folder_id >= 0 && model.next_folder_id < 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
    return persist(selectTop({ ...model, folders: [...model.folders, { id: model.next_folder_id, name: candidate }], selected_folder: model.next_folder_id,
      next_folder_id: model.next_folder_id >= 0 && model.next_folder_id < 4294967295 ? Math.trunc(model.next_folder_id) + 1 : 0, dialog: "closed", activity: concat([asciiBytes("Created folder "), candidate]) }));
  }
  if (folderById(model, model.dialog_folder) === null) return stay({ ...model, dialog: "closed" });
  return persist({ ...model, folders: model.folders.map((folder, index) => folder !== undefined && index === model.folders.findIndex((folder) => folder.id === model.dialog_folder) ? { ...folder, name: candidate } : folder),
    dialog: "closed", activity: concat([asciiBytes("Renamed folder to "), candidate]) });
}
function copy(model: Model, id: number): Step {
  const note = noteById(model, id); if (note === null) return stay(model);
  return { model: { ...model, activity: utf8Bytes("Copying…") }, effect: "copy", clipboard: note.body.text };
}
function move(model: Model, direction: number): Model {
  const rows = visible(model); if (rows.length === 0) return model;
  const at = rows.findIndex((note) => note.id === model.active_note);
  const index = at < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, at + direction));
  return { ...model, active_note: rows[index].id };
}
function transition(model: Model, msg: Msg): Step {
  switch (msg.kind) {
    case "seed_clock": return stay(seedAt(model, msg.stamp));
    case "data_dir_set": {
      const suffix = asciiBytes("/store.txt");
      const path = msg.value.length === 0 || msg.value.length + suffix.length > 512 ? asciiBytes("") : concat([msg.value, suffix]);
      const next = { ...model, store_path: path };
      return { model: next, effect: "boot", clipboard: asciiBytes("") };
    }
    case "edit": {
      const found = model.notes.findIndex((note) => note.id === model.active_note);
      if (!(found >= -1 && found < 48)) throw { kind: "integer_overflow" } as NotesOverflow;
      const index = found >= -1 && found < 48 ? Math.trunc(found) : -1;
      if (index < 0 || deleted(model.notes[index])) return stay(model);
      const body = editing(model.notes[index].body, msg.event, 4096);
      return clock({ ...model, notes: model.notes.map((note, at) => note !== undefined && at === index ? { ...note, body } : note) }, { kind: "stamp_edit", edited_note_id: model.active_note });
    }
    case "clock_done": {
      const action = model.pending_clock, next: Model = { ...model, now_ms: msg.stamp, pending_clock: { kind: "idle" } };
      switch (action.kind) {
        case "idle": return stay(model);
        case "refresh": return stay(next);
        case "new_note": return newNote(next);
        case "trash": return trashNote(next, action.id);
        case "restore": return restoreNote(next, action.id);
        case "delete_folder": return deleteFolder(next, action.id);
        case "stamp_edit": {
          const editedIndex = next.notes.findIndex((n) => n.id === action.edited_note_id);
          const note = next.notes[editedIndex];
          return { model: { ...next, notes: next.notes.map((n, index) => n !== undefined && index === editedIndex ? { ...n, updated_ms: msg.stamp } : n),
            activity: asciiBytes(note.body.truncated ? "Note is full (4 KiB cap)" : "") }, effect: "save_timer", clipboard: asciiBytes("") };
        }
      }
    }
    case "search_edit": return stay({ ...model, search_buffer: editing(model.search_buffer, msg.event, 48) });
    case "folder_field_edit": return stay({ ...model, folder_field: editing(model.folder_field, msg.event, 32), dialog_hint: asciiBytes("") });
    case "select_folder": return stay(selectFolder(model, msg.id));
    case "select_folder_at": {
      if (equal(msg.position, ZERO)) return stay(selectFolder(model, 0));
      for (let i = 0; i < model.folders.length; i += 1)
        if (equal(msg.position, asciiBytes(`${i + 1}`))) return stay(selectFolder(model, model.folders[i].id));
      return stay(model);
    }
    case "select_trash": return stay(selectTop({ ...model, selected_folder: 4294967295, note_list_scroll: 0 }));
    case "open_note": return noteById(model, msg.id) === null ? stay(model) : stay({ ...model, active_note: msg.id });
    case "hover_note": return stay({ ...model, hovered_note: msg.id });
    case "unhover_note": return model.hovered_note === msg.id ? stay({ ...model, hovered_note: 0 }) : stay(model);
    case "next_note": return stay(move(model, 1));
    case "prev_note": return stay(move(model, -1));
    case "new_note": return model.folders.length === 0 ? stay(model) : clock(model, { kind: "new_note" });
    case "delete_note": { const note = active(model); return note === null ? stay(model) : deleted(note) ? purgeNote(model, note.id) : clock(model, { kind: "trash", id: note.id }); }
    case "trash_note": { const note = noteById(model, msg.id); return note === null || deleted(note) ? stay(model) : clock(model, { kind: "trash", id: msg.id }); }
    case "restore_note": { const note = noteById(model, msg.id); return note === null || !deleted(note) ? stay(model) : clock(model, { kind: "restore", id: msg.id }); }
    case "purge_note": return purgeNote(model, msg.id);
    case "copy_note": return copy(model, model.active_note);
    case "copy_note_id": return copy(model, msg.id);
    case "open_create_folder": return model.folders.length >= 6 ? stay({ ...model, activity: asciiBytes("Folder limit reached (6)") }) : stay({ ...model, dialog: "create_folder", folder_field: { ...blank(), truncated: model.folder_field.truncated }, dialog_hint: asciiBytes("") });
    case "open_rename_folder": return stay(renameDialog(model, model.selected_folder, asciiBytes("Select a folder to rename")));
    case "rename_folder": return stay(renameDialog(model, msg.id, asciiBytes("That folder is gone")));
    case "delete_folder": return folderById(model, msg.id) === null ? stay(model) : model.folders.length <= 1 ? stay({ ...model, activity: asciiBytes("Keep at least one folder") }) : clock(model, { kind: "delete_folder", id: msg.id });
    case "confirm_dialog": return confirmDialog(model);
    case "close_dialog": return stay({ ...model, dialog: "closed" });
    case "dismiss": return model.dialog !== "closed" ? stay({ ...model, dialog: "closed" }) : model.search_buffer.text.length > 0 ? stay({ ...model, search_buffer: blank() }) : stay(model);
    case "sidebar_resized": return stay({ ...model, sidebar_split: Math.fround(msg.fraction) });
    case "list_resized": return stay({ ...model, list_split: Math.fround(msg.fraction) });
    case "note_list_scrolled": return stay({ ...model, note_list_scroll: Math.fround(msg.state.offsetY) });
    case "chrome_changed": return stay({ ...model, chrome_leading: Math.fround(msg.insets.left), header_height: Math.fround(Math.max(52, msg.insets.top)) });
    case "system_scheme": return stay({ ...model, system_scheme: msg.colorScheme });
    case "refresh_tick": return clock(model, { kind: "refresh" });
    case "save_tick": return persist(model);
    case "clipboard_done": return msg.operation !== "write" ? stay(model) : stay({ ...model, activity: msg.outcome === "ok" ? asciiBytes("Copied to clipboard") : asciiBytes(`Copy failed: ${msg.outcome}`) });
    case "store_done": {
      if (msg.operation === "read") {
        if (msg.outcome === "not_found") return stay(model);
        if (msg.outcome !== "ok") return stay({ ...model, activity: asciiBytes(`Load failed: ${msg.outcome}`) });
        const store = restoreStore(msg.bytes);
        if (store === null) return stay({ ...model, activity: utf8Bytes("Store unreadable — using the built-in samples") });
        if (!(store.next_folder_id >= 1 && store.next_folder_id <= 4294967295 && store.next_note_id >= 1 && store.next_note_id <= 4294967295)) throw { kind: "integer_overflow" } as NotesOverflow;
        let next: Model = { ...model, folders: store.folders, notes: store.notes, next_folder_id: Math.trunc(store.next_folder_id), next_note_id: store.next_note_id >= 1 && store.next_note_id <= 4294967295 ? Math.trunc(store.next_note_id) : 0, activity: asciiBytes(`Loaded ${store.notes.length} notes`) };
        if (next.selected_folder !== 0 && folderById(next, next.selected_folder) === null) next = { ...next, selected_folder: 0 };
        if (next.active_note !== 0 && noteById(next, next.active_note) === null) next = { ...next, active_note: 0 };
        return next.active_note === 0 ? stay(selectTop(next)) : stay(next);
      }
      if (msg.operation === "write") {
        const next = { ...model, store_write_inflight: false };
        if (msg.outcome !== "ok") return stay({ ...next, activity: asciiBytes(`Save failed: ${msg.outcome}`) });
        return model.save_pending ? persist({ ...next, save_pending: false }) : stay({ ...next, activity: asciiBytes("Saved") });
      }
      return stay({ ...model, activity: asciiBytes(`Unexpected file operation: ${msg.operation}`) });
    }
  }
}

export function displayTitle(body: Uint8Array): Uint8Array {
  let start = 0;
  for (let end = 0; end <= body.length; end += 1) if (end === body.length || body[end] === 10) {
    const line = trim(body.slice(start, end), true); if (line.length > 0) return cut(line, 28);
    start = end + 1;
  }
  return asciiBytes("Untitled");
}
export function displaySnippet(body: Uint8Array): Uint8Array {
  let start = 0, rest = -1;
  for (let end = 0; end <= body.length; end += 1) if (end === body.length || body[end] === 10) {
    if (trim(body.slice(start, end), true).length > 0) { rest = Math.min(body.length, end + 1); break; }
    start = end + 1;
  }
  if (rest < 0) return utf8Bytes("—");
  const buffer = new Uint8Array(Math.min(body.length - rest, 31)); let length = 0, inSpace = true;
  for (let i = rest; i < body.length; i += 1) {
    const byte = body[i], space = byte === 32 || byte === 9 || byte === 10 || byte === 13;
    if (space) { if (!inSpace && length < buffer.length) { buffer[length] = 32; length += 1; } inSpace = true; continue; }
    if (length >= buffer.length) break;
    buffer[length] = byte; length += 1; inSpace = false;
  }
  while (length > 0 && buffer[length - 1] === 32) length -= 1;
  return length === 0 ? utf8Bytes("—") : cut(buffer.slice(0, length), 30);
}
function cut(text: Uint8Array, capacity: number): Uint8Array {
  if (text.length <= capacity) return text;
  let end = capacity; while (end > 0 && (text[end] & 192) === 128) end -= 1;
  while (end > 0 && text[end - 1] === 32) end -= 1;
  return concat([text.slice(0, end), utf8Bytes("…")]);
}
export function relativeTimeLabel(now: Uint8Array, then: Uint8Array): Uint8Array {
  const delta = subtractStamp(now, then);
  if (compareStamp(delta, asciiBytes("60000")) < 0) return asciiBytes("now");
  const minutes = divideMagnitude(delta, 60000); if (compareStamp(minutes, asciiBytes("60")) < 0) return concat([minutes, asciiBytes("m")]);
  const hours = divideMagnitude(minutes, 60); if (compareStamp(hours, asciiBytes("24")) < 0) return concat([hours, asciiBytes("h")]);
  const days = divideMagnitude(hours, 24); if (compareStamp(days, asciiBytes("7")) < 0) return concat([days, asciiBytes("d")]);
  const weeks = divideMagnitude(days, 7); if (compareStamp(weeks, asciiBytes("52")) < 0) return concat([weeks, asciiBytes("w")]);
  return concat([divideMagnitude(days, 365), asciiBytes("y")]);
}
export function countWords(text: Uint8Array): number {
  let count = 0, inWord = false;
  for (const byte of text) {
    if (byte === 32 || byte === 9 || byte === 10 || byte === 13) inWord = false;
    else if (!inWord) { inWord = true; count += 1; }
  }
  return count;
}
export interface FolderRow { readonly id: number; readonly name: Uint8Array; readonly label: Uint8Array; readonly count: Uint8Array; readonly selected: boolean; readonly mutable: boolean; }
export interface NoteRow { readonly id: number; readonly title: Uint8Array; readonly snippet: Uint8Array; readonly time: Uint8Array; readonly active: boolean; readonly deleted: boolean; }
export interface ShortcutHint { readonly keys: Uint8Array; readonly action: Uint8Array; }
export function search(model: Model): Uint8Array { return model.search_buffer.text; }
export function foldersFull(model: Model): boolean { return model.folders.length >= 6; }
export function trashAvailable(model: Model): boolean { return model.notes.some(deleted); }
export function trashSelected(model: Model): boolean { return model.selected_folder === TRASH; }
export function trashCount(model: Model): Uint8Array { return asciiBytes(`${model.notes.filter(deleted).length}`); }
export function folderRows(model: Model): FolderRow[] {
  const live = model.notes.filter((note) => !deleted(note));
  const all: FolderRow = { id: 0, name: asciiBytes("All Notes"), label: asciiBytes("All Notes folder"), count: asciiBytes(`${live.length}`), selected: model.selected_folder === 0, mutable: false };
  return [all, ...model.folders.map((folder) => ({ id: folder.id, name: folder.name, label: concat([folder.name, asciiBytes(" folder")]),
    count: asciiBytes(`${live.filter((note) => note.folder === folder.id).length}`), selected: model.selected_folder === folder.id, mutable: true }))];
}
export function listTitle(model: Model): Uint8Array {
  const folder = folderById(model, model.selected_folder);
  return model.selected_folder === TRASH ? asciiBytes("Recently Deleted") : folder === null ? asciiBytes("All Notes") : folder.name;
}
export function noteCount(model: Model): Uint8Array { return asciiBytes(`${visible(model).length}`); }
export function noteRows(model: Model): NoteRow[] {
  return visible(model).map((note) => ({ id: note.id, title: displayTitle(note.body.text), snippet: displaySnippet(note.body.text),
    time: relativeTimeLabel(model.now_ms, note.updated_ms), active: model.active_note === note.id, deleted: deleted(note) }));
}
export function emptyTitle(model: Model): Uint8Array { return asciiBytes(model.search_buffer.text.length > 0 ? "No matches" : "No notes here yet"); }
export function emptyHint(model: Model): Uint8Array { return asciiBytes(model.search_buffer.text.length > 0 ? "Search covers every folder's full text." : "Press Cmd+N or the New note button to start one."); }
export function hasActiveNote(model: Model): boolean { return active(model) !== null; }
export function activeNoteLive(model: Model): boolean { const note = active(model); return note !== null && !deleted(note); }
export function editorText(model: Model): Uint8Array { const note = active(model); return note === null ? asciiBytes("") : note.body.text; }
export function editorMeta(model: Model): Uint8Array {
  const note = active(model); if (note === null) return asciiBytes("");
  const age = relativeTimeLabel(model.now_ms, deleted(note) ? note.deleted_ms : note.updated_ms);
  return concat([asciiBytes(deleted(note) ? "Deleted " : "Edited "), equal(age, asciiBytes("now")) ? asciiBytes("just now") : concat([age, asciiBytes(" ago")]), utf8Bytes(` · ${countWords(note.body.text)} words`)]);
}
export function dialogOpen(model: Model): boolean { return model.dialog !== "closed"; }
export function dialogTitle(model: Model): Uint8Array { return asciiBytes(model.dialog === "rename_folder" ? "Rename Folder" : "New Folder"); }
export function dialogConfirmLabel(model: Model): Uint8Array { return asciiBytes(model.dialog === "rename_folder" ? "Rename" : "Create"); }
export function folderName(model: Model): Uint8Array { return model.folder_field.text; }
export function dialogNameEmpty(model: Model): boolean { return model.folder_field.text.length === 0; }
export function statusLine(model: Model): Uint8Array {
  const note = noteById(model, model.hovered_note);
  if (note !== null && model.hovered_note !== 0) {
    const age = relativeTimeLabel(model.now_ms, deleted(note) ? note.deleted_ms : note.updated_ms);
    return concat([displayTitle(note.body.text), utf8Bytes(deleted(note) ? " · Deleted " : " · Edited "), equal(age, asciiBytes("now")) ? asciiBytes("just now") : concat([age, asciiBytes(" ago")]), utf8Bytes(` · ${countWords(note.body.text)} words`)]);
  }
  const prefix = utf8Bytes(`${model.notes.filter((n) => !deleted(n)).length} notes · ${visible(model).length} shown`);
  return model.activity.length === 0 ? prefix : concat([prefix, utf8Bytes(" · "), model.activity]);
}
export function shortcut_hints(model: Model): ShortcutHint[] {
  return [{ keys: asciiBytes("Cmd+N"), action: asciiBytes("New note in the selected folder") },
    { keys: asciiBytes("Cmd+Shift+N"), action: asciiBytes("New folder") }, { keys: asciiBytes("Cmd+Shift+R"), action: asciiBytes("Rename the selected folder") },
    { keys: asciiBytes("Cmd+Backspace"), action: asciiBytes("Delete the open note") }, { keys: asciiBytes("Cmd+Shift+C"), action: asciiBytes("Copy the open note") },
    { keys: asciiBytes("Cmd+Opt+Up / Down"), action: asciiBytes("Previous / next note") }, { keys: utf8Bytes("Cmd+1 … Cmd+7"), action: asciiBytes("Jump to a folder") },
    { keys: asciiBytes("Esc"), action: asciiBytes("Close a menu or dialog, clear search") }];
}
export function tokenOverrides(model: Model): ThemeDesignTokenOverrides { return { colors: notesColors(model.system_scheme), radius: { sm: 6, md: 8, lg: 11, xl: 14 } }; }
export function themeState(model: Model): ThemeState { return { colorScheme: model.system_scheme }; }

export function commandMsg(name: Uint8Array): Msg | null {
  if (equal(name, asciiBytes("notes.new-note"))) return { kind: "new_note" };
  if (equal(name, asciiBytes("notes.new-folder"))) return { kind: "open_create_folder" };
  if (equal(name, asciiBytes("notes.rename-folder"))) return { kind: "open_rename_folder" };
  if (equal(name, asciiBytes("notes.delete-note"))) return { kind: "delete_note" };
  if (equal(name, asciiBytes("notes.copy-note"))) return { kind: "copy_note" };
  if (equal(name, asciiBytes("notes.prev-note"))) return { kind: "prev_note" };
  if (equal(name, asciiBytes("notes.next-note"))) return { kind: "next_note" };
  if (equal(name, asciiBytes("notes.dismiss"))) return { kind: "dismiss" };
  const prefix = asciiBytes("notes.folder-");
  if (name.length <= prefix.length || !equal(name.slice(0, prefix.length), prefix)) return null;
  let at = prefix.length;
  if (name[at] === 43) at += 1;
  if (at === name.length || name[at] === 95 || name[name.length - 1] === 95) return null;
  const digits: number[] = [];
  for (let i = at; i < name.length; i += 1) {
    const byte = name[i]; if (byte === 95) continue;
    if (byte < 48 || byte > 57) return null;
    if (digits.length > 0 || byte !== 48) digits.push(byte);
  }
  if (digits.length === 0) return null;
  const value = new Uint8Array(digits);
  if (compareMagnitude(value, asciiBytes("18446744073709551615")) > 0) return null;
  return { kind: "select_folder_at", position: subtractStamp(value, asciiBytes("1")) };
}

function seedAt(model: Model, now: Uint8Array): Model {
  const folders: Folder[] = [{ id: 1, name: asciiBytes("Inbox") }, { id: 2, name: asciiBytes("Ideas") }, { id: 3, name: asciiBytes("Reading") }];
  const notes: Note[] = [];
  const stamp0=subtractStamp(now, asciiBytes("691200000"));
  notes.push({ id: 1, folder: 3, created_ms: stamp0, updated_ms: stamp0, deleted_ms: ZERO, body: textState(utf8Bytes("Piranesi\n\nThe halls, the tides, the statues. Reread the flooding scene — the calm inventory voice is what makes it land."), 4096) });
  const stamp1=subtractStamp(now, asciiBytes("345600000"));
  notes.push({ id: 2, folder: 3, created_ms: stamp1, updated_ms: stamp1, deleted_ms: ZERO, body: textState(utf8Bytes("The Making of Prince of Persia\n\nJordan Mechner's journals. The rotoscoping chapter pairs well with the animation notes in Ideas."), 4096) });
  const stamp2=subtractStamp(now, asciiBytes("172800000"));
  notes.push({ id: 3, folder: 2, created_ms: stamp2, updated_ms: stamp2, deleted_ms: ZERO, body: textState(utf8Bytes("Reading queue mechanics\n\nThe queue should surface the oldest unread item, not the newest. Novelty is the enemy of finishing."), 4096) });
  const stamp3=subtractStamp(now, asciiBytes("93600000"));
  notes.push({ id: 4, folder: 2, created_ms: stamp3, updated_ms: stamp3, deleted_ms: ZERO, body: textState(utf8Bytes("Field recorder for the balcony\n\nA tiny app that samples one minute of audio at sunrise and files it by date. Could pair with the weather log."), 4096) });
  const stamp4=subtractStamp(now, asciiBytes("18000000"));
  notes.push({ id: 5, folder: 1, created_ms: stamp4, updated_ms: stamp4, deleted_ms: ZERO, body: textState(utf8Bytes("Platform sync — Thursday\n\nDecisions:\n- Folders stay at a fixed capacity, loudly\n- Keyboard shortcuts land with the first release\n\nFollow-ups:\n- Snippet truncation at word boundaries"), 4096) });
  const stamp5=subtractStamp(now, asciiBytes("10800000"));
  notes.push({ id: 6, folder: 1, created_ms: stamp5, updated_ms: stamp5, deleted_ms: ZERO, body: textState(utf8Bytes("Groceries\n\n- Coffee beans\n- Oat milk\n- Rye bread\n- Lemons\n- Parmesan"), 4096) });
  const stamp6=subtractStamp(now, asciiBytes("120000"));
  notes.push({ id: 7, folder: 1, created_ms: stamp6, updated_ms: stamp6, deleted_ms: ZERO, body: textState(utf8Bytes("Welcome to Notes\n\nEverything here is a real note — edit this text and watch the list re-sort by edit time.\n\nThe first line of a note becomes its title, the next lines become the preview, and search covers every folder's full text. Notes autosave a moment after you stop typing.\n\nThe whole keyboard map is on the right when no note is open; start with Cmd+N."), 4096) });
  return selectTop({ ...model, folders, notes, next_folder_id: 4, next_note_id: 8, selected_folder: 0, now_ms: now });
}

export function initialModel(): [Model, Cmd<Msg>] {
  const model: Model = { folders: [], notes: [], next_folder_id: 1, next_note_id: 1, selected_folder: 0, active_note: 0, search_buffer: blank(), folder_field: blank(), dialog: "closed", dialog_folder: 0, dialog_hint: asciiBytes(""), store_path: asciiBytes(""), store_write_inflight: false, save_pending: false, system_scheme: "light", now_ms: ZERO, activity: asciiBytes(""), sidebar_split: Math.fround(0.19), list_split: Math.fround(0.33), note_list_scroll: 0, hovered_note: 0, chrome_leading: 0, header_height: 52, pending_clock: { kind: "idle" } };
  return [seedAt(model, ZERO), Cmd.wallTime("seed_clock")];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  const next = transition(model, msg);
  switch (next.effect) {
    case "none": return next.model;
    case "persist": return [next.model, Cmd.writeFileResult(next.model.store_path, serializeStore(next.model), { key: "2", result: "store_done" })];
    case "clock": return [next.model, Cmd.wallTime("clock_done")];
    case "save_timer": return [next.model, Cmd.timerResult("save", 800, "one_shot", { result: "save_tick" })];
    case "copy": return [next.model, Cmd.clipboardWriteResult(next.clipboard, { key: "3", result: "clipboard_done" })];
    case "boot": return [next.model, next.model.store_path.length === 0
      ? Cmd.timerResult("refresh", 30000, "repeating", { result: "refresh_tick" })
      : Cmd.batch([Cmd.readFileResult(next.model.store_path, { key: "1", result: "store_done" }), Cmd.timerResult("refresh", 30000, "repeating", { result: "refresh_tick" })])];
  }
}
