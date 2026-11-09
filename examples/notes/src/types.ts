import { type TextSelection, type TextRange } from "@native-sdk/core/text";
export interface TextBuffer { readonly text: Uint8Array; readonly selection: TextSelection; readonly composition: TextRange | null; readonly truncated: boolean; }
export interface Folder { readonly id: number; readonly name: Uint8Array; }
export interface Note {
  readonly id: number; readonly folder: number;
  readonly created_ms: Uint8Array; readonly updated_ms: Uint8Array; readonly deleted_ms: Uint8Array;
  readonly body: TextBuffer;
}
export interface Store {
  readonly folders: readonly Folder[]; readonly notes: readonly Note[];
  readonly next_folder_id: number; readonly next_note_id: number;
}

export interface NotesOverflow { readonly kind: "integer_overflow"; }
