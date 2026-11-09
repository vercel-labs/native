import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { ChromeInsets, ChromeButtons, ColorScheme, ScrollState, ThemeState } from "@native-sdk/core/events";
import type { TextInputEvent } from "@native-sdk/core/text";
import type { ThemeDesignTokenOverrides } from "@native-sdk/core/theme";
import { blankText, blankImage, sample, reconcile, transition, serializeRecent, title, basename, equal, type ViewerText, type RecentPath, type PreviewImage, type ViewerIdentity } from "./state.ts";
import { sampleTable, type Sample } from "./samples.ts";
import { viewerTheme } from "./theme.ts";

export interface Model {
  readonly editor: ViewerText; readonly path_field: ViewerText;
  readonly current_path: Uint8Array; readonly pending_path: Uint8Array;
  readonly recents: readonly RecentPath[]; readonly recent_path: Uint8Array;
  readonly details_expanded: readonly boolean[];
  readonly active_sample_id: number; readonly sample_picker_open: boolean;
  readonly system_scheme: ColorScheme; readonly note: Uint8Array;
  readonly chrome_leading: number; readonly chrome_trailing: number; readonly toolbar_height: number;
  readonly doc_scroll: number; readonly preview_images: readonly PreviewImage[];
  readonly target_os: Uint8Array;
}
export type FileOutcome = "ok" | "not_found" | "io_failed" | "truncated" | "rejected" | "cancelled" | "sink_missing" | "out_of_order" | "disk_full";
export type FileEvent = "terminal" | "chunk" | "done";
export type FileOperation = "read" | "write" | "append" | "stat" | "read_stream" | "write_stream_open" | "write_stream_chunk" | "write_stream_close" | "delete";
export type ViewerImageState = "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed" | "tls_failed" | "protocol_failed" | "timed_out" | "http_status" | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full" | "alloc_failed";
export type ExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export type Msg =
  | { readonly kind: "edit"; readonly edit: TextInputEvent }
  | { readonly kind: "edit_path"; readonly edit: TextInputEvent }
  | { readonly kind: "load_sample"; readonly id: number }
  | { readonly kind: "toggle_sample_picker" } | { readonly kind: "close_sample_picker" }
  | { readonly kind: "open_recent"; readonly index: number }
  | { readonly kind: "open_doc" } | { readonly kind: "save_doc" } | { readonly kind: "save_as" }
  | { readonly kind: "appearance"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean }
  | { readonly kind: "doc_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "toggle_details"; readonly index: number }
  | { readonly kind: "open_url"; readonly url: Uint8Array }
  | { readonly kind: "file_done"; readonly key: Uint8Array; readonly operation: FileOperation; readonly event: FileEvent; readonly outcome: FileOutcome; readonly bytes: Uint8Array; readonly totalBytes: Uint8Array; readonly mtimeMs: Uint8Array; readonly exists: boolean; readonly droppedBefore: number }
  | { readonly kind: "recent_done"; readonly key: Uint8Array; readonly operation: FileOperation; readonly event: FileEvent; readonly outcome: FileOutcome; readonly bytes: Uint8Array; readonly totalBytes: Uint8Array; readonly mtimeMs: Uint8Array; readonly exists: boolean; readonly droppedBefore: number }
  | { readonly kind: "image_done"; readonly imageLower: number; readonly imageUpper: number; readonly state: ViewerImageState; readonly width: number; readonly height: number; readonly status: number }
  | { readonly kind: "link_done"; readonly key: Uint8Array; readonly code: number; readonly reason: ExitReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean }
  | { readonly kind: "target_os"; readonly os: Uint8Array }
  | { readonly kind: "app_data"; readonly path: Uint8Array };
export const chromeMsg = "chrome_changed";
export const appearanceMsg = "appearance";
export const envMsgs = [{ env: "NATIVE_SDK_TARGET_OS", msg: "target_os" }, { env: "NATIVE_SDK_APP_LEGACY_DATA_DIR", msg: "app_data" }] as const;
export const viewUnbound = ["editor", "path_field", "current_path", "pending_path", "recents", "recent_path", "system_scheme", "note", "preview_images", "target_os", "file_done", "recent_done", "image_done", "link_done", "app_data"] as const;

export function initialModel(): Model | [Model, Cmd<Msg>] {
  const images: PreviewImage[] = []; for (let i = 0; i < 12; i++) images.push(blankImage());
  const model: Model = {
    editor: blankText(), path_field: blankText(), current_path: asciiBytes(""), pending_path: asciiBytes(""), recents: [], recent_path: asciiBytes(""),
    details_expanded: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false],
    active_sample_id: 0, sample_picker_open: false, system_scheme: "light", note: asciiBytes(""),
    chrome_leading: 0, chrome_trailing: 0, toolbar_height: 48, doc_scroll: 0, preview_images: images, target_os: asciiBytes(""),
  };
  const plan = reconcile(sample(model, 1));
  return [plan.model, Cmd.imageBatchWords(plan.images, { event: "image_done" })];
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  const plan = transition(model, msg), next = plan.model;
  return [next, Cmd.batch([
    Cmd.imageBatchWords(plan.images, { event: "image_done" }),
    plan.read.length > 0 ? Cmd.readFileResult(plan.read, { key: "1", replace: false, result: "file_done" }) : Cmd.none,
    plan.write.length > 0 ? Cmd.writeFileResult(plan.write, next.editor.text, { key: "2", replace: false, result: "file_done" }) : Cmd.none,
    plan.persist && next.recent_path.length > 0 ? Cmd.writeFileResult(next.recent_path, serializeRecent(next), { key: "4", replace: false, result: "recent_done" }) : Cmd.none,
    plan.restore && next.recent_path.length > 0 ? Cmd.readFileResult(next.recent_path, { key: "3", replace: false, result: "recent_done" }) : Cmd.none,
    plan.browser !== null ? Cmd.spawnEvents(equal(next.target_os, asciiBytes("windows"))
      ? [asciiBytes("cmd"), asciiBytes("/c"), asciiBytes("start"), asciiBytes(""), plan.browser]
      : equal(next.target_os, asciiBytes("macos")) ? [asciiBytes("open"), plan.browser] : [asciiBytes("xdg-open"), plan.browser], { key: "5", collect: true, exit: "link_done" }) : Cmd.none,
  ])];
}
export function document(model: Model): Uint8Array { return model.editor.text; }
export function path(model: Model): Uint8Array { return model.path_field.text; }
export function pathEmpty(model: Model): boolean { return model.path_field.text.length === 0; }
export function cannotSave(model: Model): boolean { return model.current_path.length === 0; }
export function docTitle(model: Model): Uint8Array { return title(model); }
export function samples(model: Model): readonly Sample[] { return sampleTable; }
export interface RecentDoc { readonly index: number; readonly name: Uint8Array; readonly path: Uint8Array; }
export function recentDocs(model: Model): readonly RecentDoc[] {
  const output: RecentDoc[] = [];
  for (let index = 0; index < model.recents.length && index < 6; index++) {
    const recent = model.recents[index];
    output.push({ index, name: basename(recent.value, equal(model.target_os, asciiBytes("windows"))), path: recent.value });
  }
  return output;
}
export interface MarkdownImage { readonly source: Uint8Array; readonly image: ViewerIdentity; readonly width: number; readonly height: number; }
export function markdownImages(model: Model): readonly MarkdownImage[] {
  const output: MarkdownImage[] = [];
  for (const image of model.preview_images) if (image.loaded) output.push({ source: image.source, image: image.identity, width: image.width, height: image.height });
  return output;
}
export function statusLine(model: Model): Uint8Array {
  let words = 0, lines = model.editor.text.length > 0 ? 1 : 0, inWord = false;
  for (const byte of model.editor.text) {
    if (byte === 10) lines++;
    if (byte === 32 || byte === 9 || byte === 10 || byte === 13) inWord = false;
    else if (!inWord) { words++; inWord = true; }
  }
  const counts = utf8Bytes(`${words} words · ${lines} lines · ${model.editor.text.length} bytes`);
  if (model.note.length === 0) return counts;
  const join = utf8Bytes(" · "), output = new Uint8Array(counts.length + join.length + model.note.length);
  output.set(counts); output.set(join, counts.length); output.set(model.note, counts.length + join.length); return output;
}
export function themeState(model: Model): ThemeState { return { colorScheme: model.system_scheme }; }
export function tokenOverrides(model: Model): ThemeDesignTokenOverrides { return viewerTheme(model.system_scheme); }
