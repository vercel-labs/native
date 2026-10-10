import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { intakeCases } from "./intake_cases.ts";

assert.ok(process.argv[2], "run with the compiled corewire path");
const corewire = path.resolve(process.argv[2]);
// Mirror hashes include the reviewed stateless-runtime API addition.
// Facade hashes include exact u32 image identities, nonreplacing file
// results and exact-range timers. Removing the reviewed timer encoder
// addition recovers every previous complete facade pin. The byte-key
// encoder and bounded 4 MiB view changes are also audited against those
// complete pins; their removal recovers the earlier generator output.
// Exact audio and close/minimize encoder additions are likewise audited
// by recovering each complete earlier facade after removing those blocks.
// Exact subprocess and cancellation records are independently audited:
// removing only their encoder cases recovers every preceding complete facade.
const goldens = JSON.parse(fs.readFileSync(new URL("intake_goldens.json", import.meta.url), "utf8")) as Record<string, { status: number; diagnostics: string; hashes: Record<string, string> }>;
for (const item of intakeCases()) test(item.name, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-intake-"));
  try {
    fs.writeFileSync(path.join(dir, "input.json"), item.input);
    const flags = item.mode === "core" ? { mirror: "--out", facade: "--facade", profile: "--profile", effective: "--effective-sidecar" } : { host: "--service-host-main", registry: "--service-registry", client: "--service-client", inproc: "--service-inproc-main", profile: "--service-inproc-profile" };
    for (const file of Object.keys(flags)) fs.writeFileSync(path.join(dir, file), "retain");
    const result = spawnSync(corewire, [item.mode === "core" ? "--sidecar" : "--services-sidecar", "input.json", ...Object.entries(flags).flatMap(([file, flag]) => [flag, file])], { cwd: dir, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    assert.ifError(result.error); assert.equal(result.signal, null, result.stderr);
    const golden = goldens[item.name]; assert.ok(golden, "missing native reference");
    assert.equal(result.status, golden.status, result.stderr); assert.equal(result.stderr, golden.diagnostics);
    for (const file of Object.keys(flags)) assert.equal(createHash("sha256").update(fs.readFileSync(path.join(dir, file))).digest("hex"), golden.hashes[file], file);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
