import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { aliasPaths, identityPlan, metadataIdentity, outputBegin, outputStep, pathBegin, pathComponent, pathObserved, stagingPath } from "./filesystem_coordination.ts";
import type { FileOutput, Observation, OutputAction } from "./filesystem_coordination.ts";
import { textBytes } from "./invocation.ts";
import { invocationCases } from "./invocation_cases.ts";
import { invoke } from "./invocation_fixture.ts";
import { baseContract as coreContract } from "./core_cases.ts";
import { baseContract as serviceContract } from "./service_cases.ts";

const bytes = textBytes;
const text = (raw: number[]) => Buffer.from(raw).toString("utf8");
const output = (kind: string, name: string): FileOutput => ({ kind, flag: "--" + kind, path: bytes(name), parent: bytes("."), staged: [] });
const ok = (): Observation => ({ ok: true, error: [], bytes: [0, 1, 2, 3, 4, 5, 6, 255], identity: false });
function trace(mode: string, outputs: FileOutput[], observe: (action: OutputAction) => Observation = ok) {
  let state = outputBegin(mode, structuredClone(outputs)), observation = ok();
  const actions: OutputAction[] = [];
  for (let i = 0; i < 200; i++) {
    const step = outputStep(state, observation); state = step.state; actions.push(step.action);
    if (step.action.kind === "done") return { state, actions };
    observation = observe(step.action);
  }
  throw new Error("output coordinator failed to finish");
}
test("path traversal resumes canonicalization after a nonexistent tail is popped", () => {
  assert.deepEqual(pathBegin(null, false, null), { state: { base: bytes("."), exists: true }, resolve: false });
  assert.equal(pathBegin(bytes("C:"), false, bytes("unused")).resolve, true);
  let state = pathBegin(bytes("/"), true, null).state;
  assert.deepEqual(pathComponent(state, bytes(".")), { action: "keep", probe: false });
  state = pathObserved(state, "join", bytes("/missing"), null);
  assert.equal(state.exists, false);
  assert.deepEqual(pathComponent(state, bytes("child")), { action: "join", probe: false });
  assert.deepEqual(pathComponent(state, bytes("..")), { action: "parent", probe: true });
  state = pathObserved(state, "parent", bytes("/"), bytes("/real"));
  assert.deepEqual(state, { base: bytes("/real"), exists: true });
  assert.deepEqual(pathComponent(state, bytes("link")), { action: "join", probe: true });
  assert.deepEqual(pathObserved(state, "parent", bytes("/"), null), { base: bytes("/"), exists: true });
});
test("identity decisions compare full exact metadata and preserve observation precedence", () => {
  const a = { canonical: bytes("/a/file"), basename: bytes("file"), parent: bytes("/a"), metadata: null };
  assert.deepEqual(identityPlan(a, a), { same: true, stat: false });
  assert.deepEqual(identityPlan(a, { ...a, canonical: bytes("/b/file"), parent: bytes("/b") }), { same: false, stat: true });
  assert.deepEqual(identityPlan(a, { ...a, canonical: null }), { same: false, stat: false });
  assert.deepEqual(identityPlan(a, { ...a, canonical: bytes("/a/other"), basename: bytes("other") }), { same: false, stat: false });
  const values = ["18446744073709551615", "directory", "9007199254740993", "18446744073709551615", "-170141183460469231731687303715884105728", "170141183460469231731687303715884105727"];
  assert.equal(metadataIdentity(values, values.slice()), true);
  for (let i = 0; i < 6; i++) { const changed = values.slice(); changed[i] += "0"; assert.equal(metadataIdentity(values, changed), false); }
  assert.equal(metadataIdentity(null, values), false);
});
test("raw staging names preserve every entropy bit and every path byte", () => {
  const raw = [0xff, 0x80, 0, 0x5c];
  const out = stagingPath(raw, [0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xff]);
  assert.deepEqual(out.slice(0, 4), raw);
  assert.equal(text(out.slice(4)), ".corewire-tmp.00123456789abcff");
  assert.deepEqual(aliasPaths([output("out", "a"), output("facade", "b")]).map(text), ["a", "b", "a.corewire-tmp", "b.corewire-tmp"]);
});
test("all core outputs stage before any commit, with a fresh alias net at each phase", () => {
  const result = trace("core", [output("mirror", "a"), output("facade", "b")]);
  assert.equal(result.state.exit_code, 0);
  assert.deepEqual(result.actions.map(a => a.kind), ["mkdir", "entropy", "create", "write", "flush", "close", "identity", "mkdir", "entropy", "create", "write", "flush", "close", "rename", "identity", "rename", "done"]);
});
for (const failure of ["create", "write", "flush", "rename"]) for (const index of [0, 1]) {
  test(`complete ${failure} failure cleanup at output ${index}`, () => {
    const result = trace("core", [output("mirror", "a"), output("facade", "b")], a => ({ ...ok(), ok: !(a.kind === failure && a.index === index), error: bytes("Denied") }));
    assert.equal(result.state.exit_code, 1);
    const deleted = result.actions.filter(a => a.kind === "delete").map(a => text(a.path));
    const suffix = ".corewire-tmp.00010203040506ff";
    assert.deepEqual(deleted, failure === "rename" ? ["a", "b"].slice(index).map(p => p + suffix)
      : [...(failure === "create" ? [] : [(index ? "b" : "a") + suffix]), ...["a", "b"].slice(0, index).map(p => p + suffix)]);
    const kinds = result.actions.map(a => a.kind);
    if (failure === "write") assert.equal(result.actions.some(a => a.kind === "flush" && a.index === index), false);
    assert.equal(kinds.filter(k => k === "diagnostic").length, 1);
    assert.equal(kinds.at(-1), "done");
    assert.equal(text(result.state.error).includes("earlier projections were already replaced"), failure === "rename" && index === 1);
    if (failure !== "rename" && index === 1) assert.ok(kinds.indexOf("diagnostic") < kinds.lastIndexOf("delete"));
  });
}
for (const commit of [false, true]) test(`late identity refusal at ${commit ? "commit" : "staging"} cleans only remaining owned files`, () => {
  let seen = 0;
  const result = trace("core", [output("mirror", "a"), output("facade", "b")], a => ({ ...ok(), identity: a.kind === "identity" && ++seen === (commit ? 2 : 1) }));
  assert.equal(result.state.exit_code, 2);
  assert.deepEqual(result.actions.filter(a => a.kind === "delete").map(a => text(a.path)), [(commit ? "b" : "a") + ".corewire-tmp.00010203040506ff"]);
  assert.equal(text(result.state.error).includes("just wrote"), commit);
});
test("service projection remains sequential, including overlapping outputs and a later refusal", () => {
  const outputs = [output("registry", "same"), output("client", "same"), output("inproc_profile", "profile")];
  const result = trace("service", outputs, a => ({ ...ok(), ok: !(a.kind === "service_write" && a.index === 1), error: bytes("Denied") }));
  assert.equal(result.state.exit_code, 1);
  assert.deepEqual(result.actions.map(a => a.kind), ["generate", "service_write", "generate", "service_write", "diagnostic", "done"]);
  assert.deepEqual(result.actions.filter(a => a.kind === "generate").map(a => a.projection), ["registry", "client"]);
  const success = trace("service", outputs);
  assert.deepEqual(success.actions.filter(a => a.kind === "generate").map(a => a.projection), ["registry", "client", "profile"]);
});

if (process.argv[2] && process.argv[3]) {
  const candidate = path.resolve(process.argv[2]), reference = path.resolve(process.argv[3]);
  for (const item of invocationCases()) test("full native-reference invocation: " + item.name, () => {
    assert.deepEqual(invoke(candidate, item), invoke(reference, item));
  });
  type Scenario = { name: string; args: string[]; setup: (dir: string) => void; malformed?: boolean };
  const scenarios: Scenario[] = [
    { name: "all core projections with missing parents", args: ["--sidecar", "input.json", "--out", "missing/a", "--facade", "missing/b", "--profile", "missing/c", "--effective-sidecar", "missing/d"], setup: () => {} },
    { name: "earlier output unchanged after second staging refuses", args: ["--sidecar", "input.json", "--out", "a", "--facade", "blocked/b"], setup: dir => { fs.writeFileSync(path.join(dir, "a"), "retain"); fs.writeFileSync(path.join(dir, "blocked"), "file"); } },
    { name: "second rename refuses after first commit", args: ["--sidecar", "input.json", "--out", "a", "--facade", "directory"], setup: dir => { fs.writeFileSync(path.join(dir, "a"), "retain"); fs.mkdirSync(path.join(dir, "directory")); } },
    { name: "first rename refuses and all stages are removed", args: ["--sidecar", "input.json", "--out", "directory", "--facade", "b"], setup: dir => { fs.mkdirSync(path.join(dir, "directory")); fs.writeFileSync(path.join(dir, "b"), "retain"); } },
    { name: "case folded future spelling alias", args: ["--sidecar", "input.json", "--out", "a", "--facade", "A"], setup: () => {} },
    { name: "service partial outputs after write failure", args: ["--services-sidecar", "services.json", "--service-registry", "registry", "--service-client", "missing/client"], setup: () => {} },
    { name: "service sequential overlapping outputs", args: ["--services-sidecar", "services.json", "--service-registry", "same", "--service-client", "same", "--service-inproc-main", "inproc", "--service-inproc-profile", "inproc"], setup: () => {} },
  ];
  if (process.platform !== "win32") scenarios.push(
    { name: "symlink input refusal precedes malformed decode", args: ["--sidecar", "input.json", "--out", "alias"], malformed: true, setup: dir => fs.symlinkSync("input.json", path.join(dir, "alias")) },
    { name: "dot-dot applies after symlink resolution", args: ["--sidecar", "input.json", "--out", "link/../b"], setup: dir => { fs.mkdirSync(path.join(dir, "real/sub"), { recursive: true }); fs.symlinkSync("real/sub", path.join(dir, "link")); fs.symlinkSync("../input.json", path.join(dir, "real/b")); } },
    { name: "canonical traversal resumes after nonexistent tail", args: ["--sidecar", "input.json", "--out", "missing/../alias"], malformed: true, setup: dir => fs.symlinkSync("input.json", path.join(dir, "alias")) },
    { name: "hard link output replaces entry without overwriting input", args: ["--sidecar", "input.json", "--out", "hard"], setup: dir => fs.linkSync(path.join(dir, "input.json"), path.join(dir, "hard")) },
    { name: "symlink ancestors produce one future output", args: ["--sidecar", "input.json", "--out", "real/new", "--facade", "link/new"], setup: dir => { fs.mkdirSync(path.join(dir, "real")); fs.symlinkSync("real", path.join(dir, "link")); } },
    { name: "decomposed and composed unicode names retain OS behavior", args: ["--sidecar", "input.json", "--out", "é", "--facade", "e\u0301"], setup: () => {} },
  );
  function outcome(binary: string, scenario: Scenario) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-filesystem-conformance-"));
    try {
      fs.writeFileSync(path.join(dir, "input.json"), scenario.malformed ? "{" : JSON.stringify(coreContract(), (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
      fs.writeFileSync(path.join(dir, "services.json"), JSON.stringify(serviceContract())); scenario.setup(dir);
      const result = spawnSync(binary, scenario.args, { cwd: dir, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
      assert.ifError(result.error); assert.equal(result.signal, null, result.stderr);
      const entries: Record<string, string> = {};
      function collect(relative: string) {
        for (const item of fs.readdirSync(path.join(dir, relative), { withFileTypes: true })) {
          const name = relative ? relative + "/" + item.name : item.name, p = path.join(dir, name);
          entries[name] = item.isSymbolicLink() ? "link:" + fs.readlinkSync(p) : item.isDirectory() ? "directory" : createHash("sha256").update(fs.readFileSync(p)).digest("hex");
          if (item.isDirectory()) collect(name);
        }
      }
      collect("");
      return { status: result.status, stdout: result.stdout, diagnostics: result.stderr.replaceAll(fs.realpathSync(dir), ".").replaceAll(dir, ".").replace(/\.corewire-tmp\.[0-9a-f]{16}/g, ".corewire-tmp.NONCE"), entries };
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }
  for (const scenario of scenarios) test("full filesystem reference: " + scenario.name, () => {
    assert.deepEqual(outcome(candidate, scenario), outcome(reference, scenario));
  });
  if (fs.existsSync("/dev/full")) test("diagnostic write failure still removes every earlier stage", () => {
    function failedDiagnostic(binary: string) {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-filesystem-diagnostic-"));
      try {
        fs.writeFileSync(path.join(dir, "input.json"), JSON.stringify(coreContract(), (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value));
        fs.writeFileSync(path.join(dir, "blocked"), "file");
        const descriptor = fs.openSync("/dev/full", "w");
        let result;
        try {
          result = spawnSync(binary, ["--sidecar", "input.json", "--out", "a", "--facade", "blocked/b"], { cwd: dir, stdio: ["ignore", "pipe", descriptor] });
        } finally { fs.closeSync(descriptor); }
        assert.ifError(result.error);
        assert.equal(result.signal, null);
        assert.equal(result.status, 1);
        const entries = fs.readdirSync(dir).sort();
        assert.deepEqual(entries, ["blocked", "input.json"]);
        return { status: result.status, stdout: result.stdout, entries };
      } finally { fs.rmSync(dir, { recursive: true, force: true }); }
    }
    assert.deepEqual(failedDiagnostic(candidate), failedDiagnostic(reference));
  });
}
