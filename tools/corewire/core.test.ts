import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { baseContract, coreCases } from "./core_cases.ts";

assert.ok(process.argv[2], "run with the compiled corewire path (zig build test-corewire-policy)");
const corewire = path.resolve(process.argv[2]);
// Exact diagnostics and complete generated-file hashes captured from the
// independent native implementation before replacing its admission rules.
// Mirror hashes include the reviewed stateless-runtime API addition.
// Facade hashes include exact u32 image identities, nonreplacing file
// results and exact-range timers. Removing the reviewed timer encoder
// addition recovers every previous complete facade pin. The byte-key
// encoder and bounded 4 MiB view changes are also audited against those
// complete pins; their removal recovers the earlier generator output.
const goldens = JSON.parse(fs.readFileSync(new URL("core_goldens.json", import.meta.url), "utf8")) as Record<string, {
  status: number; diagnostics: string; hashes: Record<string, string>;
  check_status: number; check_diagnostics: string;
}>;
const flags = { mirror: "--out", facade: "--facade", profile: "--profile", effective: "--effective-sidecar" };
for (const item of coreCases()) test(item.name, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-contract-"));
  try {
    fs.writeFileSync(path.join(dir, "input.json"), item.input);
    const files = item.mirrorOnly ? ["mirror"] : Object.keys(flags);
    for (const file of files) fs.writeFileSync(path.join(dir, file), "retain");
    const overrides = (item.slots ?? []).flatMap(slot => ["--f64-slot", slot]);
    const args = ["--sidecar", "input.json", ...files.flatMap(file => [flags[file as keyof typeof flags], file]), ...overrides];
    const result = spawnSync(corewire, args, { cwd: dir, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    assert.ifError(result.error); assert.equal(result.signal, null, result.stderr);
    const golden = goldens[item.name]; assert.ok(golden, "missing independent native reference");
    assert.equal(result.status, golden.status, result.stderr); assert.equal(result.stderr, golden.diagnostics);
    for (const file of files) {
      const bytes = fs.readFileSync(path.join(dir, file));
      assert.equal(createHash("sha256").update(bytes).digest("hex"), golden.hashes[file], file);
      if (result.status !== 0) assert.equal(bytes.toString(), "retain", "refusal wrote an output");
    }
    const checked = spawnSync(corewire, ["--sidecar", "input.json", "--check", ...overrides], { cwd: dir, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    assert.ifError(checked.error); assert.equal(checked.signal, null, checked.stderr);
    assert.equal(checked.status, golden.check_status, checked.stderr); assert.equal(checked.stderr, golden.check_diagnostics);
    for (const file of files) assert.equal(createHash("sha256").update(fs.readFileSync(path.join(dir, file))).digest("hex"), golden.hashes[file], "check wrote an output");
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});


test("parameterized arena helpers and retained integer estimators keep the attested codecs", () => {
  const contract = baseContract();
  contract.types.structs.push({ name: "Range", origin: "src/events.ts", exported: true, fields: [
    { name: "first", type: { kind: "i64" } }, { name: "geometry", type: { kind: "f64" } },
  ] });
  contract.model_helpers.push(
    { name: "rows", params: [{ kind: "value", name: "Range" }, { kind: "optional", inner: { kind: "bytes" } }], returns: { kind: "slice", elem: { kind: "value", name: "Range" } }, arena: true },
    { name: "estimate", params: [{ kind: "i64" }], returns: { kind: "f64" }, arena: false },
  );
  contract.integer_slots.push({ slot: "Range.first", class: "i64" }, { slot: "helpers.estimate.params[0]", class: "u64" });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-helper-codecs-"));
  try {
    fs.writeFileSync(path.join(dir, "input.json"), JSON.stringify(contract, (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
    const result = spawnSync(corewire, ["--sidecar", "input.json", "--out", "mirror", "--facade", "facade"], { cwd: dir, encoding: "utf8" });
    assert.ifError(result.error); assert.equal(result.status, 0, result.stderr);
    const mirror = fs.readFileSync(path.join(dir, "mirror"), "utf8"), facade = fs.readFileSync(path.join(dir, "facade"), "utf8");
    assert.match(mirror, /pub fn rows\(self: \*const Model, p0: Range, p1: \?\[\]const u8, arena: std.mem.Allocator\)/);
    assert.match(mirror, /pub fn rows\(self: \*const RuntimeModel, p0: Range, p1: \?\[\]const u8, arena: std.mem.Allocator\)/);
    assert.match(mirror, /pub fn snapshotModel/);
    assert.match(mirror, /decoded_model = null/);
    assert.match(mirror, /const args_tuple = \.\{ p0, p1 \}/);
    assert.match(mirror, /pub fn virtualExtentHelper/);
    assert.match(mirror, /pub fn virtualExtentEstimate/);
    assert.match(mirror, /callHelper\(\[\]const Range, 0, args, arena\)/);
    assert.match(mirror, /@bitCast\(@as\(u64, @intCast\(index\)\)\)/);
    assert.match(facade, /rows\(nscfCommitted,/);
    assert.match(facade, /estimate\(nscfCommitted,/);
    for (const name of ["virtualExtentHelper", "virtualExtentEstimate", "RuntimeModel", "RuntimeResult", "decoded_model", "restoreCommittedModel"]) {
      const conflicting = structuredClone(contract);
      conflicting.model_helpers[1].name = name;
      conflicting.integer_slots.find(slot => slot.slot === "helpers.estimate.params[0]")!.slot = `helpers.${name}.params[0]`;
      fs.writeFileSync(path.join(dir, "input.json"), JSON.stringify(conflicting, (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
      fs.writeFileSync(path.join(dir, "mirror"), "retain");
      const refused = spawnSync(corewire, ["--sidecar", "input.json", "--out", "mirror"], { cwd: dir, encoding: "utf8" });
      assert.ifError(refused.error); assert.equal(refused.status, 1, refused.stderr);
      assert.match(refused.stderr, /collides with a declaration the generated shim/);
      assert.equal(fs.readFileSync(path.join(dir, "mirror"), "utf8"), "retain");
      if (name !== "virtualExtentHelper" && name !== "virtualExtentEstimate") continue;
      const fieldConflict = structuredClone(contract);
      fieldConflict.types.structs[0].fields.push({ name, type: { kind: "f64" } });
      fs.writeFileSync(path.join(dir, "input.json"), JSON.stringify(fieldConflict, (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
      const fieldRefused = spawnSync(corewire, ["--sidecar", "input.json", "--out", "mirror"], { cwd: dir, encoding: "utf8" });
      assert.ifError(fieldRefused.error); assert.equal(fieldRefused.status, 1, fieldRefused.stderr);
      assert.match(fieldRefused.stderr, /model field .*collides with a declaration the generated shim/);
      assert.equal(fs.readFileSync(path.join(dir, "mirror"), "utf8"), "retain");
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("Markdown recipe wrapper names reserve only when window policy glue is emitted", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-markdown-collision-"));
  try {
    for (const declaration of ["helper", "type"] as const) for (const enabled of [false, true]) {
      const contract = baseContract();
      if (enabled) contract.abi.exports.push("native_window_policy");
      if (declaration === "helper") {
        contract.model_helpers.push({ name: "nativeMarkdownPolicy", params: [], returns: { kind: "f64" }, arena: false });
      } else {
        contract.types.enums.push({ name: "nativeMarkdownPolicy", origin: "src/core.ts", exported: true, members: ["first", "second"] });
        contract.types.structs[0].fields[1].type = { kind: "enum", name: "nativeMarkdownPolicy" };
      }
      fs.writeFileSync(path.join(dir, "input.json"), JSON.stringify(contract, (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
      fs.writeFileSync(path.join(dir, "mirror"), "retain");
      const result = spawnSync(corewire, ["--sidecar", "input.json", "--out", "mirror"], { cwd: dir, encoding: "utf8" });
      assert.ifError(result.error); assert.equal(result.signal, null, result.stderr);
      assert.equal(result.status, enabled ? 1 : 0, result.stderr);
      if (enabled) {
        assert.match(result.stderr, /nativeMarkdownPolicy.*collides with a declaration the generated shim/);
        assert.equal(fs.readFileSync(path.join(dir, "mirror"), "utf8"), "retain", "refusal wrote an output");
      } else {
        assert.doesNotMatch(fs.readFileSync(path.join(dir, "mirror"), "utf8"), /pub fn nativeMarkdownPolicy\(request:/);
      }
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
