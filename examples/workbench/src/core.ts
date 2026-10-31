import { Cmd, asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, caretSelectionAt, type TextEditState, type TextSelection, type TextInputEvent } from "@native-sdk/core/text";
import { type TerminalState, type ExactWebViewPane, type ChromeInsets, type ChromeButtons } from "@native-sdk/core/events";

export type WorkbenchPtyState = "output" | "exit";
export type WorkbenchExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export interface WorkbenchCounter { readonly upper_word: number; readonly lower_word: number; }
export interface WorkbenchComposition { readonly start: number; readonly end: number; }
export interface AddressBuffer { readonly text: Uint8Array; readonly selection: TextSelection; readonly composition: WorkbenchComposition | null; readonly truncated: boolean; }
export type WorkbenchOverflow = { readonly kind: "counter_overflow" };
export interface Model {
  readonly split_fraction: number;
  readonly term_scrollback: number;
  readonly chrome_top: number;
  readonly address_field: AddressBuffer;
  readonly history: readonly AddressBuffer[];
  readonly history_count: number;
  readonly history_index: number;
  readonly reload_token: WorkbenchCounter;
  readonly shell_live: boolean;
  readonly shell_exited: boolean;
  readonly output_batches: WorkbenchCounter;
}
export type Msg =
  | { readonly kind: "target_os"; readonly os: Uint8Array }
  | { readonly kind: "shell"; readonly key: Uint8Array; readonly state: WorkbenchPtyState; readonly bytes: Uint8Array; readonly code: number; readonly reason: WorkbenchExitReason; readonly signal: number; readonly droppedWrites: number }
  | { readonly kind: "split_resized"; readonly fraction: number }
  | { readonly kind: "term_state"; readonly state: TerminalState }
  | { readonly kind: "address_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "navigate" } | { readonly kind: "go_back" }
  | { readonly kind: "go_forward" } | { readonly kind: "reload" }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };
export const chromeMsg = "chrome_changed";
export const envMsgs = [{ env: "NATIVE_SDK_TARGET_OS", msg: "target_os" }] as const;
export const viewUnbound = ["history", "history_index", "history_count", "address_field", "reload_token", "shell_live", "shell_exited", "output_batches", "chrome_top"] as const;
function buffer(text: Uint8Array, truncated: boolean): AddressBuffer {
  return { text, selection: caretSelectionAt(text.length, text.length), composition: null, truncated };
}
export function initialModel(): Model {
  const home = buffer(asciiBytes("https://ziglang.org"), false);
  const history: AddressBuffer[] = [home];
  for (let i = 1; i < 32; i++) history.push(buffer(asciiBytes(""), false));
  return { split_fraction: Math.fround(1 / 3), term_scrollback: 0, chrome_top: 0, address_field: home, history, history_count: 1, history_index: 0,
    reload_token: { upper_word: 0, lower_word: 0 }, shell_live: false, shell_exited: false, output_batches: { upper_word: 0, lower_word: 0 } };
}
function increment(count: WorkbenchCounter): WorkbenchCounter {
  const lower_word = (count.lower_word + 1) >>> 0;
  const upper_word = (count.upper_word + (lower_word === 0 ? 1 : 0)) >>> 0;
  return { upper_word, lower_word };
}
function commitNavigation(model: Model): Model {
  const raw = model.address_field.text;
  let start = 0, end = raw.length;
  while (start < end && raw[start] === 32) start++;
  while (end > start && raw[end - 1] === 32) end--;
  if (start === end) return model;
  let url = raw.subarray(start, end), scheme = false;
  for (let i = 0; i + 2 < url.length; i++) if (url[i] === 58 && url[i + 1] === 47 && url[i + 2] === 47) scheme = true;
  if (!scheme && url.length + 8 <= 1024) {
    const normalized = new Uint8Array(url.length + 8);
    normalized.set(asciiBytes("https://")); normalized.set(url, 8); url = normalized;
  }
  let index = model.history_count > 0 ? model.history_index + 1 : model.history_index;
  const history: AddressBuffer[] = [...model.history];
  if (index >= 32) { history.shift(); history.push(model.history[31] ?? buffer(asciiBytes(""), false)); index = 31; }
  const previous = history[index];
  history[index] = buffer(url, previous?.truncated ?? false);
  return { ...model, history, history_count: index + 1, history_index: index, address_field: buffer(url, model.address_field.truncated) };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "target_os": {
      const os = msg.os;
      const macos = os.length === 5 && os[0] === 109 && os[1] === 97 && os[2] === 99 && os[3] === 111 && os[4] === 115;
      const windows = os.length === 7 && os[0] === 119 && os[1] === 105 && os[2] === 110 && os[3] === 100 && os[4] === 111 && os[5] === 119 && os[6] === 115;
      return [model, Cmd.ptySpawn(windows ? [asciiBytes("cmd.exe")] : [asciiBytes(macos ? "/bin/zsh" : "/bin/sh"), asciiBytes("-i")], { key: "shell", event: "shell", cols: 80, rows: 24 })];
    }
    case "shell":
      if (msg.state === "exit") return { ...model, shell_live: false, shell_exited: true };
      if (model.output_batches.upper_word === 4294967295 && model.output_batches.lower_word === 4294967295) throw { kind: "counter_overflow" } as WorkbenchOverflow;
      return { ...model, shell_live: true, output_batches: increment(model.output_batches) };
    case "split_resized": return { ...model, split_fraction: Math.fround(msg.fraction) };
    case "term_state": return { ...model, term_scrollback: msg.state.scrollback >>> 0 };
    case "address_edit": {
      const next = applyTextInputEvent(model.address_field, msg.edit, 1024);
      if (next !== null) return { ...model, address_field: { ...next, truncated: false } };
      const clamped = clampedInsertEvent(model.address_field, msg.edit, 1024);
      const recovered = clamped === null ? model.address_field : applyTextInputEvent(model.address_field, clamped, 1024) ?? model.address_field;
      return { ...model, address_field: { ...recovered, truncated: true } };
    }
    case "navigate": return commitNavigation(model);
    case "go_back": {
      if (model.history_index === 0) return model;
      const index = model.history_index - 1, entry = model.history[index];
      return entry === undefined ? model : { ...model, history_index: index >= 0 && index < 32 ? Math.trunc(index) : 0, address_field: buffer(entry.text, model.address_field.truncated) };
    }
    case "go_forward": {
      if (model.history_count === 0 || model.history_index + 1 >= model.history_count) return model;
      const index = model.history_index + 1, entry = model.history[index];
      return entry === undefined ? model : { ...model, history_index: index >= 0 && index < 32 ? Math.trunc(index) : 0, address_field: buffer(entry.text, model.address_field.truncated) };
    }
    case "reload": return { ...model, reload_token: increment(model.reload_token) };
    case "chrome_changed": return { ...model, chrome_top: Math.fround(msg.insets.top) };
  }
}
export function shell_key(_: Model): Uint8Array { return asciiBytes("shell"); }
export function address(model: Model): Uint8Array { return model.address_field.text; }
export function back_disabled(model: Model): boolean { return model.history_index === 0; }
export function forward_disabled(model: Model): boolean { return model.history_count === 0 || model.history_index + 1 >= model.history_count; }
export function titlebar_band(model: Model): number { return Math.max(38, Math.fround(model.chrome_top + 8)); }
export function currentUrl(model: Model): Uint8Array { return model.history_count === 0 ? asciiBytes("https://ziglang.org") : model.history[model.history_index]?.text ?? asciiBytes("https://ziglang.org"); }
function countText(count: WorkbenchCounter): Uint8Array {
  const digits = new Uint8Array(20); let at = 20, high = count.upper_word, low = count.lower_word;
  do {
    let quotientHigh = 0, quotientLow = 0, remainder = 0;
    for (let bit = 63; bit >= 0; bit--) {
      const shift = bit >= 32 ? bit - 32 : bit, word = bit >= 32 ? high : low;
      remainder = remainder * 2 + ((word >>> shift) & 1);
      if (remainder >= 10) { remainder -= 10; if (bit >= 32) quotientHigh = (quotientHigh | (1 << shift)) >>> 0; else quotientLow = (quotientLow | (1 << shift)) >>> 0; }
    }
    at--; digits[at] = 48 + remainder; high = quotientHigh; low = quotientLow;
  } while (high !== 0 || low !== 0);
  return digits.subarray(at);
}
export function webPanes(model: Model): readonly ExactWebViewPane[] {
  return [{ label: asciiBytes("workbench-web"), anchor: asciiBytes("web-pane"), url: currentUrl(model), x: 0, y: 0, width: 0, height: 0, reloadToken: countText(model.reload_token) }];
}
