import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("the devhost performs record-store batches, reads, and prefix scans", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly hits: number; readonly pageCount: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "again" }
  | { readonly kind: "wrote" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "scanned"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { hits: 0, pageCount: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.store.setMany([
      ["chat/1", asciiBytes("one")], ["chat/2", asciiBytes("two")],
    ], { key: "seed", ok: "wrote", err: "failed" })];
    case "wrote":
    case "again": return [model, Cmd.store.get("chat/1", { key: "read", ok: "loaded", err: "failed" })];
    case "loaded": return [{ ...model, hits: msg.bytes[0] }, Cmd.store.scan("chat/", { limit: 1 }, { key: "page", ok: "scanned", err: "failed" })];
    case "scanned": return { ...model, pageCount: msg.bytes[0] };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n{"restart":true}\n{"kind":"again"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src", "devhost.ts"), core, "--script", script], {
      cwd: tmp,
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd store_set_many seed \(2 records stored atomically\)/);
    assert.match(run.stdout, /cmd store_get read chat\/1 \(hit\)/);
    assert.match(run.stdout, /cmd store_scan page chat\/ \(1 records, more\)/);
    assert.match(run.stdout, /"hits":1,"pageCount":1/);
    assert.equal((run.stdout.match(/cmd store_get read chat\/1 \(hit\)/g) ?? []).length, 2);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
