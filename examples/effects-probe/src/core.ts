import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";

export type CounterOverflow = { readonly kind: "counter_overflow" };
export type ExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export type ClipboardOutcome = "ok" | "failed" | "rejected" | "cancelled";
export type ClipboardOperation = "read" | "write";
export interface LineCount { readonly upper_word: number; readonly lower_word: number; }
export interface Line { readonly line: Uint8Array; }
export interface Exit {
  readonly key: Uint8Array; readonly code: number; readonly reason: ExitReason;
  readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean;
  readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean;
}
export interface Model {
  readonly lines: readonly Line[];
  readonly total_lines: LineCount;
  readonly dropped_lines: number;
  readonly streaming: boolean;
  readonly last_exit: Exit | null;
  readonly copied: ClipboardOutcome | null;
  readonly windows: boolean;
}
export type Msg =
  | { readonly kind: "start" }
  | { readonly kind: "cancel" }
  | { readonly kind: "copy_status" }
  | { readonly kind: "target_os"; readonly value: Uint8Array }
  | { readonly kind: "line"; readonly key: Uint8Array; readonly line: Uint8Array; readonly truncated: boolean; readonly droppedBefore: number }
  | { readonly kind: "exited"; readonly key: Uint8Array; readonly code: number; readonly reason: ExitReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean }
  | { readonly kind: "copied"; readonly key: Uint8Array; readonly operation: ClipboardOperation; readonly outcome: ClipboardOutcome; readonly text: Uint8Array; readonly droppedBefore: number };
export const envMsgs = [{ env: "NATIVE_SDK_TARGET_OS", msg: "target_os" }] as const;
export const viewUnbound = ["last_exit", "copied", "windows", "total_lines", "dropped_lines", "lines"] as const;
export function initialModel(): Model {
  return { lines: [], total_lines: { upper_word: 0, lower_word: 0 }, dropped_lines: 0, streaming: false, last_exit: null, copied: null, windows: false };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "target_os": return { ...model, windows: msg.value.length === 7 && msg.value[0] === 119 && msg.value[1] === 105 && msg.value[2] === 110 && msg.value[3] === 100 && msg.value[4] === 111 && msg.value[5] === 119 && msg.value[6] === 115 };
    case "start": {
      if (model.streaming) return model;
      const next: Model = { ...model, streaming: true, last_exit: null, total_lines: { upper_word: 0, lower_word: 0 }, lines: [] };
      if (model.windows) return [next, Cmd.spawnEvents([asciiBytes("cmd"), asciiBytes("/q"), asciiBytes("/c"), asciiBytes("for /L %i in (1,1,500) do (ping -n 2 127.0.0.1 > nul & echo stream line %i)")], { key: "1", line: "line", exit: "exited" })];
      return [next, Cmd.spawnEvents([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes('i=0; while [ $i -lt 500 ]; do i=$((i+1)); echo "stream line $i"; sleep 0.2; done')], { key: "1", line: "line", exit: "exited" })];
    }
    case "cancel": return [model, Cmd.cancel("1")];
    case "copy_status": return [model, Cmd.clipboardWriteResult(joined([asciiBytes("effects-probe: "), countText(model.total_lines), utf8Bytes(` lines total, ${model.dropped_lines} dropped`)]), { key: "2", result: "copied" })];
    case "line": {
      const low = (model.total_lines.lower_word + 1) >>> 0;
      const high = (model.total_lines.upper_word + (low === 0 ? 1 : 0)) >>> 0;
      if (low === 0 && high === 0) throw { kind: "counter_overflow" } as CounterOverflow;
      const dropped = model.dropped_lines + msg.droppedBefore;
      if (!(dropped >= 0 && dropped <= 4294967295)) throw { kind: "counter_overflow" } as CounterOverflow;
      return { ...model, lines: [...(model.lines.length === 24 ? model.lines.slice(1) : model.lines), { line: msg.line.subarray(0, 64) }], total_lines: { upper_word: high, lower_word: low }, dropped_lines: Math.trunc(dropped) };
    }
    case "exited": return { ...model, streaming: false, last_exit: { key: msg.key, code: msg.code, reason: msg.reason, droppedLines: msg.droppedLines, output: msg.output, outputTruncated: msg.outputTruncated, stderrTail: msg.stderrTail, stderrTruncated: msg.stderrTruncated } };
    case "copied": return { ...model, copied: msg.outcome };
  }
}
export function visible(model: Model): readonly Line[] { return model.lines; }
export function statusText(model: Model): Uint8Array {
  if (model.streaming) return joined([asciiBytes("streaming: "), countText(model.total_lines), asciiBytes(" lines")]);
  const exit = model.last_exit;
  return exit === null ? asciiBytes("idle") : joined([utf8Bytes(`${exit.reason}: code ${exit.code} after `), countText(model.total_lines), asciiBytes(" lines")]);
}
export function copyLabel(model: Model): Uint8Array { return asciiBytes(model.copied === null ? "Copy status" : model.copied === "ok" ? "Copied" : "Copy failed"); }
export function totals(model: Model): Uint8Array { return joined([countText(model.total_lines), utf8Bytes(` lines total · ${model.dropped_lines} dropped`)]); }

// Two exact words retain the native u64 counter beyond JavaScript's safe
// integer range. Decimal long division never computes an inexact u64 number.
function countText(count: LineCount): Uint8Array {
  const digits = new Uint8Array(20);
  let at = 20;
  let high = count.upper_word;
  let low = count.lower_word;
  do {
    let quotientHigh = 0;
    let quotientLow = 0;
    let remainder = 0;
    for (let bit = 63; bit >= 0; bit--) {
      const shift = bit >= 32 ? bit - 32 : bit;
      const word = bit >= 32 ? high : low;
      remainder = remainder * 2 + ((word >>> shift) & 1);
      if (remainder >= 10) {
        remainder -= 10;
        if (bit >= 32) quotientHigh = (quotientHigh | (1 << shift)) >>> 0;
        else quotientLow = (quotientLow | (1 << shift)) >>> 0;
      }
    }
    at -= 1;
    digits[at] = 48 + remainder;
    high = quotientHigh;
    low = quotientLow;
  } while (high !== 0 || low !== 0);
  return digits.subarray(at);
}
function joined(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0;
  for (const part of parts) length += part.length;
  const result = new Uint8Array(length);
  let at = 0;
  for (const part of parts) { result.set(part, at); at += part.length; }
  return result;
}

export function idle(model: Model): boolean { return !model.streaming; }
