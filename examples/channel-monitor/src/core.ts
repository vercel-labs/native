import { Cmd, utf8Bytes } from "@native-sdk/core";

export interface SampleCount { readonly upper_word: number; readonly lower_word: number; }
export interface Line { readonly bytes: Uint8Array; readonly length: number; }
export interface Model {
  readonly line_storage: readonly Line[];
  readonly visible_count: number;
  readonly total_samples: SampleCount;
  readonly dropped_total: number;
  readonly monitoring: boolean;
  readonly rejected: boolean;
  readonly source_failed: boolean;
}
export type ChannelState = "data" | "closed" | "rejected";
export type ChannelSourceState = "started" | "skipped" | "failed";
export type Msg =
  | { readonly kind: "start" }
  | { readonly kind: "stop" }
  | { readonly kind: "sample"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "source_started"; readonly key: number; readonly state: ChannelSourceState; readonly bytes: Uint8Array };
export const viewUnbound = ["line_storage", "visible_count", "total_samples", "dropped_total", "rejected", "source_failed", "sample", "source_started"] as const;
interface CounterOverflow { readonly kind: "counter_overflow"; }

export function initialModel(): Model {
  const lines: Line[] = [];
  for (let i = 0; i < 16; i++) lines.push({ bytes: new Uint8Array(96), length: 0 });
  return { line_storage: lines, visible_count: 0, total_samples: { upper_word: 0, lower_word: 0 }, dropped_total: 0, monitoring: false, rejected: false, source_failed: false };
}

function resetRun(model: Model): Model {
  return { ...model, visible_count: 0, total_samples: { upper_word: 0, lower_word: 0 }, dropped_total: 0, rejected: false, source_failed: false };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "start": {
      if (model.monitoring) return model;
      return [resetRun(model), Cmd.channelOpenSource(1, "native-sdk.process.samples", new Uint8Array(0), { event: "sample", started: "source_started" })];
    }
    case "source_started": {
      if (msg.state === "failed") return [{ ...model, source_failed: true }, Cmd.channelClose(1)];
      return { ...model, monitoring: true };
    }
    case "stop": return [model, Cmd.channelClose(1)];
    case "sample": {
      if (msg.state === "closed") {
        const dropped = msg.droppedTotal >= 0 && msg.droppedTotal <= 4294967295 ? Math.trunc(msg.droppedTotal) : 0;
        return { ...model, monitoring: false, dropped_total: dropped };
      }
      if (msg.state === "rejected") return { ...model, monitoring: false, rejected: true };
      const lower_word = (model.total_samples.lower_word + 1) >>> 0;
      const upper_word = (model.total_samples.upper_word + (lower_word === 0 ? 1 : 0)) >>> 0;
      if (lower_word === 0 && upper_word === 0) throw { kind: "counter_overflow" } as CounterOverflow;
      const lines = model.line_storage.slice();
      let count = model.visible_count;
      if (count === 16) {
        for (let i = 0; i < 15; i++) lines[i] = model.line_storage[i + 1];
        count -= 1;
      }
      const target = lines[count];
      const storage = target.bytes.slice();
      const rawLength = msg.bytes.length;
      const length = rawLength >= 0 && rawLength <= 96 ? Math.trunc(rawLength) : 96;
      for (let i = 0; i < length; i++) storage[i] = msg.bytes[i];
      lines[count] = { bytes: storage, length };
      const visible_count = count >= 0 && count < 16 ? Math.trunc(count) + 1 : 16;
      const dropped = msg.droppedTotal >= 0 && msg.droppedTotal <= 4294967295 ? Math.trunc(msg.droppedTotal) : 0;
      return { ...model, line_storage: lines, visible_count, total_samples: { upper_word, lower_word }, dropped_total: dropped };
    }
  }
}

export interface VisibleLine { readonly line: Uint8Array; }
export function visible(model: Model): readonly VisibleLine[] {
  const lines: VisibleLine[] = [];
  for (let i = 0; i < model.visible_count; i++) {
    const row = model.line_storage[i];
    lines.push({ line: row.bytes.subarray(0, row.length) });
  }
  return lines;
}
export function stopped(model: Model): boolean { return !model.monitoring; }
export function totals(model: Model): Uint8Array {
  return joined([countText(model.total_samples), utf8Bytes(` samples · ${model.dropped_total} dropped`)]);
}

function countText(count: SampleCount): Uint8Array {
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
  const out = new Uint8Array(length);
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}

export function statusText(model: Model): Uint8Array {
  if (model.rejected) return utf8Bytes("channel rejected");
  if (model.source_failed) return utf8Bytes("sampler failed to start");
  const total = countText(model.total_samples);
  if (model.monitoring) {
    if (model.dropped_total > 0) return joined([utf8Bytes("monitoring: "), total, utf8Bytes(` samples, ${model.dropped_total} dropped`)]);
    return joined([utf8Bytes("monitoring: "), total, utf8Bytes(" samples")]);
  }
  if (model.total_samples.upper_word > 0 || model.total_samples.lower_word > 0) return joined([utf8Bytes("stopped after "), total, utf8Bytes(" samples")]);
  return utf8Bytes("idle");
}
