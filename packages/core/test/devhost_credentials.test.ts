import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("the devhost keeps credentials in memory and redacts its transcript", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-credentials-devhost-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly loadedLength: number; readonly writes: number; readonly deletes: number; readonly failures: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "wrote" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "deleted" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { loadedLength: 0, writes: 0, deletes: 0, failures: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.credentials.set("api-token", asciiBytes("super-secret"), { key: "write", ok: "wrote", err: "failed" })];
    case "wrote": return [{ ...model, writes: model.writes + 1 }, Cmd.credentials.get("api-token", { key: "read", ok: "loaded", err: "failed" })];
    case "loaded": return [{ ...model, loadedLength: msg.bytes.length }, Cmd.credentials.delete("api-token", { key: "delete", ok: "deleted", err: "failed" })];
    case "deleted": return [{ ...model, deletes: model.deletes + 1 }, Cmd.credentials.set("bad\\0key", asciiBytes("must-not-store"), { key: "invalid", ok: "wrote", err: "failed" })];
    case "failed": return { ...model, failures: model.failures + 1 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script,
      "--app-id", "dev.native-sdk.credentials-test",
      "--capability", "credentials", "--permission", "credentials",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /core\.credentials\.set write api-token \(<redacted, 12 bytes> stored/);
    assert.match(run.stdout, /core\.credentials\.get read api-token \(<redacted, 12 bytes>\)/);
    assert.match(run.stdout, /core\.credentials\.delete delete api-token \(deleted/);
    assert.match(run.stdout, /core\.credentials\.set rejected over_bound/);
    assert.match(run.stdout, /"loadedLength":12,"writes":1,"deletes":1,"failures":1/);
    assert.doesNotMatch(run.stdout, /super-secret/);
    assert.doesNotMatch(run.stdout, /must-not-store/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
