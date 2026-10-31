import type { TextEditState, TextInputEvent } from "@native-sdk/core/text";
export type FileOperation = "read" | "write" | "append" | "stat" | "read_stream" | "write_stream_open" | "write_stream_chunk" | "write_stream_close" | "delete";
export type FileEvent = "terminal" | "chunk" | "done";
export type FileOutcome = "ok" | "not_found" | "io_failed" | "truncated" | "rejected" | "cancelled" | "sink_missing" | "out_of_order" | "disk_full";
import type { ExplorerEntry } from "./explorer.ts";
import type { ContentHash } from "./content_hash.ts";

export interface ExactCounter {
  readonly counter_lower: number;
  readonly counter_upper: number;
}

export type DocumentState = "idle" | "loading" | "text" | "binary" | "failed";
export interface EditorDocument {
  readonly entry_index: number;
  readonly editor: TextEditState;
  readonly editor_truncated: boolean;
  readonly state: DocumentState;
  readonly source_truncated: boolean;
  readonly read_key: ExactCounter;
  readonly save_key: ExactCounter;
  readonly save_queued: boolean;
  readonly saved_len: number;
  readonly saved_hash: ContentHash;
  readonly pending_save_len: number;
  readonly pending_save_hash: ContentHash;
}

export interface BrowserState {
  readonly root: Uint8Array;
  readonly entries: readonly ExplorerEntry[];
  readonly tree_selected_entry: number | null;
  readonly selected_entry: number | null;
  readonly pinned_entries: readonly number[];
  readonly preview_entry: number | null;
  readonly hovered_tab: number | null;
  readonly renaming_entry: number | null;
  readonly pending_rename_entry: number | null;
  readonly rename_buffer: TextEditState;
  readonly rename_truncated: boolean;
  readonly rename_serial: ExactCounter;
  readonly pending_expand_entry: number | null;
  readonly expand_serial: ExactCounter;
  readonly scan_truncated: boolean;
  readonly scan_had_errors: boolean;
  readonly sidebar_fraction: number;
  readonly chrome_leading: number;
  readonly titlebar_height: number;
  readonly picker_serial: ExactCounter;
  readonly next_file_key: ExactCounter;
  readonly documents: readonly EditorDocument[];
  readonly status: Uint8Array;
}

export interface BrowserSession {
  readonly open: boolean;
  readonly pending_root: Uint8Array;
  readonly folder_token: Uint8Array;
  readonly directory_token: Uint8Array;
  readonly rename_token: Uint8Array;
  readonly handled_picker_serial: ExactCounter;
  readonly handled_rename_serial: ExactCounter;
  readonly handled_expand_serial: ExactCounter;
  readonly browser: BrowserState;
}

export interface EditorPlan {
  readonly browser: BrowserState;
  readonly read_path: Uint8Array;
  readonly read_key: Uint8Array;
  readonly write_path: Uint8Array;
  readonly write_key: Uint8Array;
  readonly write_bytes: Uint8Array;
  readonly cancel_keys: readonly Uint8Array[];
}

export type BrowserMsg =
  | { readonly kind: "open_folder" }
  | { readonly kind: "select_entry"; readonly index: number }
  | { readonly kind: "preview_entry"; readonly index: number }
  | { readonly kind: "pin_entry"; readonly index: number }
  | { readonly kind: "pin_tree_entry" }
  | { readonly kind: "begin_rename"; readonly index: number }
  | { readonly kind: "edit_rename"; readonly edit: TextInputEvent }
  | { readonly kind: "commit_rename" }
  | { readonly kind: "activate_tab"; readonly index: number }
  | { readonly kind: "hover_tab"; readonly index: number }
  | { readonly kind: "unhover_tab"; readonly index: number }
  | { readonly kind: "close_tab"; readonly index: number }
  | { readonly kind: "close_other_tabs"; readonly index: number }
  | { readonly kind: "close_active_tab" }
  | { readonly kind: "previous_tab" } | { readonly kind: "next_tab" }
  | { readonly kind: "toggle_entry"; readonly index: number }
  | { readonly kind: "edit_code"; readonly edit: TextInputEvent }
  | { readonly kind: "save_file" }
  | { readonly kind: "sidebar_resized"; readonly fraction: number }
  | { readonly kind: "file_done"; readonly key: Uint8Array; readonly operation: FileOperation; readonly event: FileEvent; readonly outcome: FileOutcome; readonly bytes: Uint8Array; readonly totalBytes: Uint8Array; readonly mtimeMs: Uint8Array; readonly exists: boolean; readonly droppedBefore: number };
