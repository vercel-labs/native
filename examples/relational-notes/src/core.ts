// The flagship relational example: migrations and named SQL are checked by
// real SQLite before this module typechecks. Writes are one atomic Cmd; the
// two result lists are maintained exclusively by generated live queries.

import {
  Cmd,
  Sub,
  dbText,
  utf8Bytes,
  decodeNotesInFolderPage,
  decodeSearchNotesPage,
} from "@native-sdk/core";

export interface NoteRow {
  readonly id: number;
  readonly title: Uint8Array;
  readonly updated_at: number;
}

export interface Model {
  readonly folderId: number;
  readonly nextId: number;
  readonly search: Uint8Array;
  readonly notes: ReadonlyArray<NoteRow>;
  readonly pendingNotes: ReadonlyArray<NoteRow>;
  readonly collectingNotes: boolean;
  readonly matches: ReadonlyArray<NoteRow>;
  readonly pendingMatches: ReadonlyArray<NoteRow>;
  readonly collectingMatches: boolean;
  readonly status: Uint8Array;
}

export type Msg =
  | { readonly kind: "seed" }
  | { readonly kind: "add_note" }
  | { readonly kind: "folder_one" }
  | { readonly kind: "folder_two" }
  | { readonly kind: "search_native" }
  | { readonly kind: "search_sqlite" }
  | { readonly kind: "notes_page"; readonly page: Uint8Array }
  | { readonly kind: "notes_done" }
  | { readonly kind: "search_page"; readonly page: Uint8Array }
  | { readonly kind: "search_done" }
  | { readonly kind: "write_ok" }
  | { readonly kind: "db_failed"; readonly reason: Uint8Array };

export const viewUnbound = [
  "folderId",
  "nextId",
  "search",
  "pendingNotes",
  "collectingNotes",
  "pendingMatches",
  "collectingMatches",
  "notes_page",
  "notes_done",
  "search_page",
  "search_done",
  "write_ok",
  "db_failed",
] as const;

function appendNotes(left: ReadonlyArray<NoteRow>, right: ReadonlyArray<NoteRow>): ReadonlyArray<NoteRow> {
  const rows: NoteRow[] = [];
  for (const row of left) rows.push(row);
  for (const row of right) rows.push(row);
  return rows;
}

function appendMatches(left: ReadonlyArray<NoteRow>, right: ReadonlyArray<NoteRow>): ReadonlyArray<NoteRow> {
  const rows: NoteRow[] = [];
  for (const row of left) rows.push(row);
  for (const row of right) rows.push(row);
  return rows;
}

export function initialModel(): Model {
  return {
    folderId: 1,
    nextId: 4,
    search: utf8Bytes("native"),
    notes: [],
    pendingNotes: [],
    collectingNotes: false,
    matches: [],
    pendingMatches: [],
    collectingMatches: false,
    status: utf8Bytes("Schema migrated; seed the demo data."),
  };
}

export function folderLabel(model: Model): Uint8Array {
  return model.folderId === 1 ? utf8Bytes("Inbox") : utf8Bytes("Archive");
}

export function noteCount(model: Model): number {
  return model.notes.length;
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "seed":
      return [
        { ...model, status: utf8Bytes("Committing folders, notes, tags, and FTS rows atomically…") },
        Cmd.qTx([
          Cmd.qInsertFolder({ id: 1, name: utf8Bytes("Inbox") }),
          Cmd.qInsertFolder({ id: 2, name: utf8Bytes("Archive") }),
          Cmd.qInsertNote({ id: 1, folder: 1, title: utf8Bytes("Build native views"), updated: 100 }),
          Cmd.qInsertNote({ id: 2, folder: 1, title: utf8Bytes("Ship checked SQLite"), updated: 200 }),
          Cmd.qInsertNote({ id: 3, folder: 2, title: utf8Bytes("Archive old draft"), updated: 50 }),
          Cmd.qInsertSearch({ id: 1, title: dbText(utf8Bytes("Build native views")) }),
          Cmd.qInsertSearch({ id: 2, title: dbText(utf8Bytes("Ship checked SQLite")) }),
          Cmd.qInsertSearch({ id: 3, title: dbText(utf8Bytes("Archive old draft")) }),
          Cmd.qInsertTag({ id: 1, name: utf8Bytes("sdk") }),
          Cmd.qTagNote({ note: 2, tag: 1 }),
        ], { key: "seed", ok: "write_ok", err: "db_failed" }),
      ];
    case "add_note": {
      const id = model.nextId;
      return [
        { ...model, nextId: id < 1000000 ? id + 1 : id, status: utf8Bytes("Adding one note and its FTS row in a transaction…") },
        Cmd.qTx([
          Cmd.qInsertNote({ id, folder: model.folderId, title: utf8Bytes("A live-query note"), updated: id }),
          Cmd.qInsertSearch({ id, title: dbText(utf8Bytes("A live-query note")) }),
        ], { key: "add-note", ok: "write_ok", err: "db_failed" }),
      ];
    }
    case "folder_one":
      return { ...model, folderId: 1, status: utf8Bytes("Live query moved to Inbox") };
    case "folder_two":
      return { ...model, folderId: 2, status: utf8Bytes("Live query moved to Archive") };
    case "search_native":
      return { ...model, search: utf8Bytes("native"), status: utf8Bytes("FTS query: native") };
    case "search_sqlite":
      return { ...model, search: utf8Bytes("SQLite"), status: utf8Bytes("FTS query: SQLite") };
    case "notes_page": {
      const decoded = decodeNotesInFolderPage(msg.page);
      return model.collectingNotes
        ? { ...model, pendingNotes: appendNotes(model.pendingNotes, decoded) }
        : { ...model, pendingNotes: decoded, collectingNotes: true };
    }
    case "notes_done":
      return { ...model, notes: model.pendingNotes, collectingNotes: false, status: utf8Bytes("Subscribed folder rows are current") };
    case "search_page": {
      const decoded = decodeSearchNotesPage(msg.page);
      return model.collectingMatches
        ? { ...model, pendingMatches: appendMatches(model.pendingMatches, decoded) }
        : { ...model, pendingMatches: decoded, collectingMatches: true };
    }
    case "search_done":
      return { ...model, matches: model.pendingMatches, collectingMatches: false };
    case "write_ok":
      return { ...model, status: utf8Bytes("Transaction committed; live queries refresh automatically") };
    case "db_failed":
      return { ...model, status: msg.reason };
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  return Sub.batch([
    Sub.qNotesInFolder("folder-notes", { folder: model.folderId }, {
      page: "notes_page",
      done: "notes_done",
      err: "db_failed",
    }),
    Sub.qSearchNotes("fts-results", { term: dbText(model.search) }, {
      page: "search_page",
      done: "search_done",
      err: "db_failed",
    }),
  ]);
}
