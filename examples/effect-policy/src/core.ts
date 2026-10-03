import { Cmd, asciiBytes, type EnvMsg } from "@native-sdk/core";

export interface Model {
  readonly path: Uint8Array;
  readonly body: Uint8Array;
  readonly status: Uint8Array;
  readonly reads: number;
  readonly latestReads: number;
  readonly writes: number;
  readonly failures: number;
  readonly clockReads: number;
  readonly clockAt: number;
  readonly exists: boolean;
  readonly size: number;
}

export type Msg =
  | { readonly kind: "data_dir_set"; readonly value: Uint8Array }
  | { readonly kind: "sample" }
  | { readonly kind: "save" }
  | { readonly kind: "append" }
  | { readonly kind: "load" }
  | { readonly kind: "replace" }
  | { readonly kind: "cancel_read" }
  | { readonly kind: "pair" }
  | { readonly kind: "inspect" }
  | { readonly kind: "delete_note" }
  | { readonly kind: "copy" }
  | { readonly kind: "paste" }
  | { readonly kind: "fetch_note" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "latest"; readonly bytes: Uint8Array }
  | { readonly kind: "saved" }
  | { readonly kind: "deleted" }
  | { readonly kind: "stat"; readonly exists: boolean; readonly size: number; readonly mtimeMs: number }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array }
  | { readonly kind: "clock"; readonly at: number };

export const envMsgs: readonly EnvMsg<Msg>[] = [{ env: "NATIVE_SDK_APP_DATA_DIR", msg: "data_dir_set" }];
export const viewUnbound = ["path", "clockAt", "data_dir_set", "loaded", "latest", "saved", "deleted", "stat", "fetched", "failed", "clock"] as const;
const SAMPLE = asciiBytes("A small note to keep.\nOne place for the next good idea.");
const SUFFIX = asciiBytes("/scratch-pad.txt");
const EXTRA = asciiBytes("\nAnd one more line.");

export function initialModel(): Model {
  return { path: asciiBytes("scratch-pad.txt"), body: SAMPLE, status: asciiBytes("Ready to save a note."),
    reads: 0, latestReads: 0, writes: 0, failures: 0, clockReads: 0, clockAt: 0, exists: false, size: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "data_dir_set": {
      if (msg.value.length === 0 || msg.value.length > 4000) return model;
      const path = new Uint8Array(msg.value.length + SUFFIX.length);
      path.set(msg.value); path.set(SUFFIX, msg.value.length);
      return { ...model, path };
    }
    case "sample": return { ...model, body: SAMPLE, status: asciiBytes("Sample ready to save.") };
    case "save": return [{ ...model, status: asciiBytes("Saving note...") }, Cmd.writeFile(model.path, model.body, { key: "note", ok: "saved", err: "failed" })];
    case "append": return [{ ...model, status: asciiBytes("Adding a line...") }, Cmd.appendFile(model.path, EXTRA, { key: "note", ok: "saved", err: "failed" })];
    case "load": return [{ ...model, status: asciiBytes("Reading note...") }, Cmd.readFile(model.path, { key: "note", ok: "loaded", err: "failed" })];
    case "replace": return [{ ...model, status: asciiBytes("Reading the latest note...") }, Cmd.batch([
      Cmd.readFile(model.path, { key: "note", ok: "loaded", err: "failed" }),
      Cmd.now("clock"),
      Cmd.readFile(model.path, { key: "note", ok: "latest", err: "failed" }),
    ])];
    case "cancel_read": return [{ ...model, status: asciiBytes("Read cancelled.") }, Cmd.batch([
      Cmd.readFile(model.path, { key: "note", ok: "loaded", err: "failed" }), Cmd.cancel("note"), Cmd.now("clock"),
    ])];
    case "pair": return [{ ...model, status: asciiBytes("Reading two copies...") }, Cmd.batch([
      Cmd.readFile(model.path, { ok: "loaded", err: "failed" }), Cmd.readFile(model.path, { ok: "latest", err: "failed" }),
    ])];
    case "inspect": return [{ ...model, status: asciiBytes("Checking the saved note...") }, Cmd.statFile(model.path, { key: "note", ok: "stat", err: "failed" })];
    case "delete_note": return [{ ...model, status: asciiBytes("Removing the saved note...") }, Cmd.deleteFile(model.path, { key: "note", ok: "deleted", err: "failed" })];
    case "copy": return [{ ...model, status: asciiBytes("Copy requested.") }, Cmd.clipboardWrite(model.body)];
    case "paste": return [{ ...model, status: asciiBytes("Reading the clipboard...") }, Cmd.clipboardRead({ key: "note", ok: "loaded", err: "failed" })];
    case "fetch_note": return [{ ...model, status: asciiBytes("Downloading a note...") }, Cmd.fetch({ url: asciiBytes("https://example.com/"), timeoutMs: 5000 }, { key: "note", ok: "fetched", err: "failed" })];
    case "loaded": return { ...model, body: msg.bytes, reads: model.reads < 1000000 ? model.reads + 1 : model.reads, status: asciiBytes("Note loaded.") };
    case "latest": return { ...model, body: msg.bytes, latestReads: model.latestReads < 1000000 ? model.latestReads + 1 : model.latestReads, status: asciiBytes("Latest read delivered.") };
    case "saved": return { ...model, writes: model.writes < 1000000 ? model.writes + 1 : model.writes, status: asciiBytes("Note saved.") };
    case "deleted": return { ...model, exists: false, size: 0, status: asciiBytes("Saved note removed.") };
    case "stat": return { ...model, exists: msg.exists, size: msg.size, status: asciiBytes(msg.exists ? "Saved note is available." : "No saved note yet.") };
    case "fetched": return { ...model, body: msg.body, reads: model.reads < 1000000 ? model.reads + 1 : model.reads, status: asciiBytes(`HTTP ${msg.status} delivered.`) };
    case "failed": return { ...model, failures: model.failures < 1000000 ? model.failures + 1 : model.failures, status: msg.reason };
    case "clock": return { ...model, clockReads: model.clockReads < 1000000 ? model.clockReads + 1 : model.clockReads, clockAt: msg.at };
  }
}

export function savedSize(model: Model): Uint8Array { return asciiBytes(model.exists ? `${model.size} bytes saved` : "No saved note"); }
