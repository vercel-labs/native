import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkFiles } from "./helpers.ts";

const serviceCore = `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly bytes: Uint8Array; }
export type Msg =
  | { readonly kind: "parse" }
  | { readonly kind: "parsed"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "parse": return [model, Cmd.request("feeds.parse", model.bytes, { key: "parse", ok: "parsed", err: "failed" })];
    case "parsed": return { bytes: msg.bytes };
    case "failed": return model;
  }
}
`;

test("service modules use the ordinary static tier and emit one registry contract", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `
import * as fs from "node:fs";
void fs;
export function parse(payload: Uint8Array): Uint8Array {
  const seen = new Map<string, number>();
  seen.set("at", Date.now());
  const text = JSON.stringify({ ok: /feed/i.test("FEED"), size: payload.length, seen: seen.size });
  return new TextEncoder().encode(text);
}
`,
  }, { contractEntry: "src/core.ts", servicesContract: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  const coreContract = JSON.parse(result.contract!);
  assert.equal(coreContract.deterministic, true);
  const contract = JSON.parse(result.servicesContract!);
  assert.equal(contract.format, 1);
  assert.equal(contract.protocol_version, 1);
  assert.equal(contract.compiler_version, "0.0.22");
  assert.equal(contract.deterministic, false);
  assert.deepEqual(contract.operations.map((op: { name: string }) => op.name), ["feeds.parse"]);
  assert.match(contract.operations[0].source_hash, /^[0-9a-f]{64}$/);
});

test("the same ambient module stays refused when it is moved into the core class", () => {
  const result = checkFiles({
    "core.ts": `
import { parse } from "./ordinary.ts";
export interface Model { readonly bytes: Uint8Array; }
export type Msg = { readonly kind: "parse" } | { readonly kind: "done"; readonly bytes: Uint8Array };
export function update(model: Model, msg: Msg): Model {
  return msg.kind === "parse" ? { bytes: parse(model.bytes) } : model;
}
`,
    "ordinary.ts": `
import * as fs from "node:fs";
export function parse(payload: Uint8Array): Uint8Array {
  const seen = new Map<string, number>();
  seen.set("at", Date.now());
  return new TextEncoder().encode(JSON.stringify({ ok: /feed/i.test("FEED"), cwd: fs.existsSync("."), seen: seen.size, size: payload.length }));
}
`,
  });
  const diagnostic = result.diagnostics.find((d) => d.id === "NS1035");
  assert.ok(diagnostic, JSON.stringify(result.diagnostics));
  assert.match(diagnostic.message, /src\/services/);
});

test("NS1065 refuses a core-to-service import, including type-only edges", () => {
  for (const clause of [
    `import { parse } from "./services/feeds.ts";`,
    `import type { Payload } from "./services/feeds.ts";`,
  ]) {
    const result = checkFiles({
      "core.ts": `${clause}\nexport interface Model { readonly n: number; }\nexport type Msg = { readonly kind: "tick" };\nexport function update(model: Model): Model { return model; }`,
      "services/feeds.ts": `export type Payload = Uint8Array; export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
    });
    assert.ok(result.diagnostics.some((d) => d.id === "NS1065"), JSON.stringify(result.diagnostics));
  }
});

test("NS1066 refuses phase-1 npm imports but permits compiler-shipped Node builtins", () => {
  const npm = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import thing from "left-pad"; export function parse(bytes: Uint8Array): Uint8Array { void thing; return bytes; }`,
  });
  assert.ok(npm.diagnostics.some((d) => d.id === "NS1066"), JSON.stringify(npm.diagnostics));

  const builtin = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import * as path from "node:path"; export function parse(bytes: Uint8Array): Uint8Array { void path; return bytes; }`,
  });
  assert.equal(builtin.ok, true, JSON.stringify(builtin.diagnostics));
});

test("NS1067 validates operation signatures, throws, and core request names", () => {
  const badSignature = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export async function parse(value: string): Promise<string> { return value; }`,
  });
  assert.ok(badSignature.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(badSignature.diagnostics));

  const badThrow = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { throw new Error("bad"); }`,
  });
  assert.ok(badThrow.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(badThrow.diagnostics));

  const taggedThrow = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { if (bytes.length === 0) throw { kind: "empty", message: "payload is empty" }; return bytes; }`,
  });
  assert.equal(taggedThrow.ok, true, JSON.stringify(taggedThrow.diagnostics));

  const extraThrowField = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { throw { kind: "bad", message: "bad payload", extra: bytes.length }; }`,
  });
  assert.ok(extraThrowField.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(extraThrowField.diagnostics));

  const reserved = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `class __nativeSdkTaggedError {} export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.ok(reserved.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(reserved.diagnostics));

  const unknown = checkFiles({
    "core.ts": serviceCore.replace("feeds.parse", "feeds.missing"),
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  const diagnostic = unknown.diagnostics.find((d) => d.id === "NS1067");
  assert.ok(diagnostic, JSON.stringify(unknown.diagnostics));
  assert.match(diagnostic.message, /services\.contract\.json/);
});

test("service staging lowers only boundary tagged throws for scriptc 0.0.22", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-stage-"));
  try {
    const src = path.join(root, "src");
    const out = path.join(root, "out");
    fs.mkdirSync(path.join(src, "services"), { recursive: true });
    fs.writeFileSync(path.join(src, "core.ts"), `export function untouched(): void { throw new Error("core"); }\n`);
    fs.writeFileSync(path.join(src, "services", "feeds.ts"), `import * as fs from "node:fs";\nexport function parse(bytes: Uint8Array): Uint8Array { if (fs.existsSync(".")) throw { kind: "fixture", message: "requested" }; return bytes; }\n`);
    const hostMain = path.join(root, "service_host_main.ts");
    fs.writeFileSync(hostMain, "// host\n");
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "stage_external_services.mjs");
    const result = spawnSync(process.execPath, [script, "--src", src, "--host-main", hostMain, "--out", out], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const service = fs.readFileSync(path.join(out, "services", "feeds.ts"), "utf8");
    assert.match(service, /class __NativeSdkTaggedError extends Error/);
    assert.match(service, /throw new __NativeSdkTaggedError\("fixture", "requested"\)/);
    assert.equal(fs.readFileSync(path.join(out, "core.ts"), "utf8"), `export function untouched(): void { throw new Error("core"); }\n`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("service and core module-scope names do not collide across the class boundary", () => {
  const result = checkFiles({
    "core.ts": `${serviceCore}\nexport interface SharedName { readonly value: number; }`,
    "services/feeds.ts": `interface SharedName { value: string; } export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
});

test("NS1038 still keeps module-scope names unique within the service class", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export interface ServiceShape { readonly bytes: Uint8Array; } export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
    "services/shared.ts": `export interface ServiceShape { readonly count: number; }`,
  });
  assert.ok(result.diagnostics.some((d) => d.id === "NS1038"), JSON.stringify(result.diagnostics));
});

test("the service compile lane refuses a contract whose compiler echo skews from the one pin", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-pin-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.22" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.21" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /contract echoes scriptc 0\.0\.21, but packages\/core pins 0\.0\.22/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
