import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { baseContract, serviceCases } from "./service_cases.ts";
import { emitHost, emitRegistry, emitClient, emitInprocProfile, validateContract, contractFingerprint } from "./emit_service.ts";

assert.ok(process.argv[2], "run with the compiled corewire path (zig build test-corewire-services)");
const corewire = path.resolve(process.argv[2]);
// Reviewed, complete projection hashes captured from the independent native
// reference before its replacement. Refusals retain the exact diagnostic bytes.
const goldens = JSON.parse(fs.readFileSync(new URL("service_goldens.json", import.meta.url), "utf8")) as Record<string, { hashes?: Record<string, string>; diagnostics?: string }>;
const flags = { host: "--service-host-main", registry: "--service-registry", client: "--service-client", inproc: "--service-inproc-main", profile: "--service-inproc-profile" };
for (const item of serviceCases()) test(item.name, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-projection-"));
  try {
    fs.writeFileSync(path.join(dir, "input.json"), item.input);
    for (const file of Object.keys(flags)) fs.writeFileSync(path.join(dir, file), "retain");
    const args = ["--services-sidecar", "input.json", ...Object.entries(flags).flatMap(([file, flag]) => [flag, file])];
    if (item.optimization) args.push("--optimization", item.optimization);
    const result = spawnSync(corewire, args, { cwd: dir, encoding: "utf8" });
    assert.ifError(result.error); assert.equal(result.signal, null, result.stderr);
    const contract = JSON.parse(item.input);
    const diagnostics = validateContract(contract, contract.operations.map((o: { module: string }) => path.basename(o.module)), item.input.match(/"format":(-?\d+)/)![1], item.input.match(/"protocol_version":(-?\d+)/)![1]);
    const golden = goldens[item.name]; assert.ok(golden, "missing independent reference");
    if (diagnostics) {
      assert.equal(result.status, 1, result.stderr); assert.equal(result.stderr, diagnostics);
      // Basename is a host fact; this one contract has different POSIX/Windows
      // validity. All other golden diagnostics are platform independent.
      if (item.name !== "host-basename") assert.equal(diagnostics, golden.diagnostics);
      for (const file of Object.keys(flags)) assert.equal(fs.readFileSync(path.join(dir, file), "utf8"), "retain");
      return;
    }
    assert.equal(result.status, 0, result.stderr);
    const outputs = { host: emitHost(contract, true), registry: emitRegistry(contract), client: emitClient(contract), inproc: emitHost(contract, false), profile: emitInprocProfile(item.optimization) };
    for (const [file, expected] of Object.entries(outputs)) {
      assert.equal(fs.readFileSync(path.join(dir, file), "utf8"), expected, file);
      assert.equal(createHash("sha256").update(expected).digest("hex"), golden.hashes![file], file);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("fingerprint owns exact ABI facts and excludes implementation-only facts", () => {
  const contract = baseContract(), original = contractFingerprint(contract);
  const implementation = structuredClone(contract);
  implementation.compiler_version = "9.9.9"; implementation.packages = [{ name: "pkg", version: "1.0.0", content_hash: "b".repeat(64) }];
  implementation.operations[0].source_hash = "c".repeat(64); implementation.operations[0].client = "renamed";
  implementation.operations[0].module = "src/services/moved.ts"; implementation.operations[0].export = "moved";
  for (const type of [...implementation.types.records, ...implementation.types.enums, ...implementation.types.unions]) type.origin = "elsewhere.ts";
  assert.deepEqual(contractFingerprint(implementation), original);
  for (const mutate of [
    (c: typeof contract) => { c.operations[0].name = "feeds.other"; },
    (c: typeof contract) => { c.operations[0].deadline_ms = 1; },
    (c: typeof contract) => { c.operations[0].cancellable = true; },
    (c: typeof contract) => { c.operations[0].stream = { chunk: c.operations[0].result, in_flight: 8 }; },
    (c: typeof contract) => { c.types.records[0].fields.reverse(); },
    (c: typeof contract) => { c.types.enums[0].members.reverse(); },
    (c: typeof contract) => { c.types.unions[0].arms.reverse(); },
  ]) { const changed = structuredClone(contract); mutate(changed); assert.notDeepEqual(contractFingerprint(changed), original); }
});

test("strict native decoding refuses malformed structural JSON before writing", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-schema-"));
  try {
    for (const input of ["{", JSON.stringify({ ...baseContract(), unexpected: true }), JSON.stringify({ ...baseContract(), format: 3.5 }), JSON.stringify({ ...baseContract(), operations: [{ ...baseContract().operations[0], cancellable: "true" }] })]) {
      fs.writeFileSync(path.join(dir, "input.json"), input); fs.writeFileSync(path.join(dir, "registry"), "retain");
      const result = spawnSync(corewire, ["--services-sidecar", "input.json", "--service-registry", "registry"], { cwd: dir, encoding: "utf8" });
      assert.ifError(result.error); assert.equal(result.status, 1); assert.match(result.stderr, /not valid schema-2 JSON/);
      assert.equal(fs.readFileSync(path.join(dir, "registry"), "utf8"), "retain");
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
