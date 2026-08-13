import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkFiles } from "./helpers.ts";
import { mergePackageSpecs, readServicePackages, replaceServicePackages, replaceVendorTree } from "../scripts/vendor_service_packages.mjs";

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
  assert.equal(contract.format, 3);
  assert.equal(contract.protocol_version, 3);
  assert.equal(contract.compiler_version, "0.0.29");
  assert.equal(contract.deterministic, false);
  assert.deepEqual(contract.packages, []);
  assert.deepEqual(contract.types, { records: [], enums: [], unions: [] });
  assert.deepEqual(contract.operations.map((op: { name: string }) => op.name), ["feeds.parse"]);
  assert.deepEqual(contract.operations[0].request, { kind: "bytes" });
  assert.deepEqual(contract.operations[0].result, { kind: "bytes" });
  assert.equal(contract.operations[0].client, "feedsParse");
  assert.match(contract.operations[0].source_hash, /^[0-9a-f]{64}$/);
});

test("a generated SQLite SDK surface and typed services share one checked program", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const generatedDir = fs.mkdtempSync(path.join(os.tmpdir(), "native-generated-sdk-services-"));
  try {
    fs.cpSync(path.join(packageDir, "sdk"), generatedDir, { recursive: true });
    const result = checkFiles({
      "core.ts": serviceCore,
      "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
    }, {
      contractEntry: "src/core.ts",
      servicesContract: true,
      sdkCorePath: path.join(generatedDir, "core.ts"),
    });
    assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
    assert.match(result.servicesClient!, /feedsParse/);
  } finally {
    fs.rmSync(generatedDir, { recursive: true, force: true });
  }
});

test("service source hashes cover transitive shared modules", () => {
  const check = (body: string) => checkFiles({
    "core.ts": serviceCore,
    "shared.ts": `export function helper(bytes: Uint8Array): Uint8Array { ${body} }`,
    "services/feeds.ts": `import { helper } from "../shared.ts"; export function parse(bytes: Uint8Array): Uint8Array { return helper(bytes); }`,
  });
  const before = check("return bytes;");
  const after = check("return bytes.slice(0, 1);");
  assert.equal(before.ok, true, JSON.stringify(before.diagnostics));
  assert.equal(after.ok, true, JSON.stringify(after.diagnostics));
  const beforeHash = JSON.parse(before.servicesContract!).operations[0].source_hash;
  const afterHash = JSON.parse(after.servicesContract!).operations[0].source_hash;
  assert.notEqual(beforeHash, afterHash);
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

test("NS1066 permits only manifest-declared npm imports and compiler-shipped Node builtins", () => {
  const npm = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import thing from "left-pad"; export function parse(bytes: Uint8Array): Uint8Array { void thing; return bytes; }`,
  });
  const diagnostic = npm.diagnostics.find((d) => d.id === "NS1066");
  assert.ok(diagnostic, JSON.stringify(npm.diagnostics));
  assert.equal(diagnostic.title, "service package imports are exact vendored facts");

  const declared = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import thing from "left-pad"; export function parse(bytes: Uint8Array): Uint8Array { void thing; return bytes; }`,
  }, { servicePackages: [{ name: "left-pad", version: "1.3.0", content_hash: "a".repeat(64) }] });
  assert.equal(declared.ok, true, JSON.stringify(declared.diagnostics));
  assert.deepEqual(JSON.parse(declared.servicesContract!).packages, [{
    name: "left-pad",
    version: "1.3.0",
    content_hash: "a".repeat(64),
  }]);

  const builtin = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import * as path from "node:path"; export function parse(bytes: Uint8Array): Uint8Array { void path; return bytes; }`,
  });
  assert.equal(builtin.ok, true, JSON.stringify(builtin.diagnostics));
});

test("record service shapes generate a typed client and stale implementations fail during check", () => {
  const core = `
import { Cmd } from "@native-sdk/core";
import { feedsParse } from "@native-sdk/services";
import type { ParseRequest, ParseResult } from "./shared.ts";
export interface Model { readonly bytes: Uint8Array; }
export type Msg =
  | { readonly kind: "go"; readonly request: ParseRequest }
  | { readonly kind: "parsed"; readonly result: ParseResult }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, feedsParse(msg.request, { key: "parse", ok: "parsed", err: "failed" })];
    case "parsed": return { bytes: msg.result.bytes };
    case "failed": return model;
  }
}`;
  const shared = `
export type ParseRequest = { readonly source: Uint8Array; readonly strict: boolean; };
export type ParseResult = { readonly bytes: Uint8Array; readonly valid: boolean; };`;
  const good = checkFiles({
    "core.ts": core,
    "shared.ts": shared,
    "services/feeds.ts": `import type { ParseRequest, ParseResult } from "../shared.ts"; export function parse(req: ParseRequest): ParseResult { return { bytes: req.source, valid: req.strict }; }`,
  }, { contractEntry: "src/core.ts", servicesContract: true });
  assert.equal(good.ok, true, JSON.stringify([...good.diagnostics, ...good.typeErrors]));
  assert.match(good.servicesClient!, /export function feedsParse\(request: ParseRequest/);
  const contract = JSON.parse(good.servicesContract!);
  assert.deepEqual(contract.operations[0].request, { kind: "record", name: "ParseRequest" });
  assert.deepEqual(contract.operations[0].result, { kind: "record", name: "ParseResult" });

  const staleService = checkFiles({
    "core.ts": core,
    "shared.ts": shared,
    "services/feeds.ts": `import type { ParseRequest, ParseResult } from "../shared.ts"; export function parse(req: ParseRequest): ParseResult { return { bytes: req.source }; }`,
  });
  assert.equal(staleService.ok, false);
  assert.ok(staleService.typeErrors.some((message) => /valid/.test(message)), JSON.stringify(staleService.typeErrors));

  const staleCore = checkFiles({
    "core.ts": core.replace("readonly result: ParseResult }", "readonly result: Uint8Array }"),
    "shared.ts": shared,
    "services/feeds.ts": `import type { ParseRequest, ParseResult } from "../shared.ts"; export function parse(req: ParseRequest): ParseResult { return { bytes: req.source, valid: req.strict }; }`,
  });
  assert.equal(staleCore.ok, false);
  assert.ok(staleCore.typeErrors.length > 0, JSON.stringify(staleCore));
});

test("the service contract carries every supported nested boundary shape", () => {
  const result = checkFiles({
    "core.ts": `
import { Cmd } from "@native-sdk/core";
import { shapesRoundTrip } from "@native-sdk/services";
import type { BoundaryRecord } from "./shared.ts";
export interface Model { readonly accepted: boolean; }
export type Msg =
  | { readonly kind: "go"; readonly request: BoundaryRecord }
  | { readonly kind: "done"; readonly result: BoundaryRecord }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, shapesRoundTrip(msg.request, { ok: "done", err: "failed" })];
    case "done": return { accepted: msg.result.enabled };
    case "failed": return model;
  }
}`,
    "shared.ts": `
export type Count = 0 | 300;
export type Flavor = "plain" | "rich";
export type Choice =
  | { readonly kind: "kept"; readonly bytes: Uint8Array }
  | { readonly kind: "skipped"; readonly count: Count };
export type BoundaryRecord = {
  readonly enabled: boolean;
  readonly ratio: number;
  readonly count: Count;
  readonly bytes: Uint8Array;
  readonly maybe: Uint8Array | null;
  readonly parts: readonly Uint8Array[];
  readonly flavor: Flavor;
  readonly choice: Choice;
};`,
    "services/shapes.ts": `
import type { BoundaryRecord } from "../shared.ts";
export function roundTrip(request: BoundaryRecord): BoundaryRecord { return request; }`,
  });
  assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
  const contract = JSON.parse(result.servicesContract!);
  assert.deepEqual(contract.operations[0].request, { kind: "record", name: "BoundaryRecord" });
  assert.deepEqual(contract.operations[0].result, { kind: "record", name: "BoundaryRecord" });
  assert.deepEqual(contract.types.enums.map((type: { name: string }) => type.name), ["Flavor"]);
  assert.deepEqual(contract.types.unions.map((type: { name: string }) => type.name), ["Choice"]);
  assert.deepEqual(contract.types.records[0].fields.map((field: { type: unknown }) => field.type), [
    { kind: "bool" },
    { kind: "f64" },
    { kind: "i64" },
    { kind: "bytes" },
    { kind: "optional", inner: { kind: "bytes" } },
    { kind: "slice", elem: { kind: "bytes" } },
    { kind: "enum", name: "Flavor" },
    { kind: "union", name: "Choice" },
  ]);
  assert.match(result.servicesClient!, /serviceBoolBytes/);
  assert.match(result.servicesClient!, /serviceF64Bytes/);
  assert.match(result.servicesClient!, /serviceI64Bytes/);
  assert.match(result.servicesClient!, /serviceOptionalBytes/);
  assert.match(result.servicesClient!, /serviceSliceBytes/);
  assert.match(result.servicesClient!, /serviceEnumBytes/);
  assert.match(result.servicesClient!, /serviceUnionBytes/);
});

test("generated clients parenthesize composite slice element types", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `
export function parse(values: readonly (Uint8Array | null)[]): readonly (Uint8Array | null)[] { return values; }`,
  });
  assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
  assert.match(result.servicesClient!, /request: readonly \(Uint8Array \| null\)\[\]/);
  assert.match(result.servicesClient!, /ServiceRoute<Msg, readonly \(Uint8Array \| null\)\[\]>/);
});

test("stream and deadline declarations are carried by the typed contract", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "shared.ts": `export type Chunk = { readonly bytes: Uint8Array; readonly index: number; };`,
    "services/feeds.ts": `
import type { Chunk } from "../shared.ts";
/**
 * @deadlineMs 1250
 * @streamBuffer 4
 */
export function parse(bytes: Uint8Array, emit: (chunk: Chunk) => void): Uint8Array { emit({ bytes, index: 0 }); return bytes; }`,
  });
  assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
  const operation = JSON.parse(result.servicesContract!).operations[0];
  assert.equal(operation.deadline_ms, 1250);
  assert.deepEqual(operation.stream, { chunk: { kind: "record", name: "Chunk" }, in_flight: 4 });
  assert.match(result.servicesClient!, /Cmd\.serviceStreamRequest\("feeds\.parse", route\.channelKey, [\s\S]+, route, 4\)/);
});

test("cooperative cancellation is a generated final service capability", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "shared.ts": `export type Chunk = { readonly bytes: Uint8Array; readonly index: number; };`,
    "services/feeds.ts": `
import type { ServiceCancellation } from "@native-sdk/core";
import type { Chunk } from "../shared.ts";
export function parse(bytes: Uint8Array, emit: (chunk: Chunk) => void, cancel: ServiceCancellation): Uint8Array {
  cancel.throwIfCancelled();
  emit({ bytes, index: 0 });
  return cancel.cancelled() ? new Uint8Array(0) : bytes;
}`,
  });
  assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
  assert.equal(JSON.parse(result.servicesContract!).operations[0].cancellable, true);

  const misplaced = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `
import type { ServiceCancellation } from "@native-sdk/core";
export function parse(cancel: ServiceCancellation, bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.ok(misplaced.diagnostics.some((diagnostic) => diagnostic.id === "NS1067" && /must be last/.test(diagnostic.message)), JSON.stringify(misplaced.diagnostics));
});

test("the staged client also materializes an ignored editor declaration package", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-editor-"));
  try {
    const src = path.join(root, "src");
    fs.mkdirSync(path.join(src, "services"), { recursive: true });
    fs.writeFileSync(path.join(src, "core.ts"), serviceCore);
    fs.writeFileSync(path.join(src, "shared.ts"), "export type Payload = { readonly bytes: Uint8Array; };\n");
    fs.writeFileSync(path.join(src, "services", "feeds.ts"), `import type { Payload } from "../shared.ts"; export function parse(value: Payload): Payload { return value; }\n`);
    const editor = path.join(root, "node_modules", "@native-sdk", "services", "index.ts");
    const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src", "cli.ts");
    const result = spawnSync(process.execPath, [cli, path.join(src, "core.ts"), "--services-editor-client", editor], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.match(fs.readFileSync(editor, "utf8"), /from "\.\.\/\.\.\/\.\.\/src\/shared\.ts"/);
    assert.match(fs.readFileSync(path.join(path.dirname(editor), "index.d.ts"), "utf8"), /feedsParse/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(path.dirname(editor), "package.json"), "utf8")).types, "./index.d.ts");
    assert.equal(fs.existsSync(path.join(src, "services.gen.ts")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("NS1067 validates operation signatures, throws, and core service call names", () => {
  const emptySurface = checkFiles({
    "core.ts": serviceCore,
    "services/helper.ts": `export class Helper { parse(bytes: Uint8Array): Uint8Array { return bytes; } }`,
  });
  const emptyDiagnostic = emptySurface.diagnostics.find((d) => d.id === "NS1067");
  assert.ok(emptyDiagnostic, JSON.stringify(emptySurface.diagnostics));
  assert.match(emptyDiagnostic.message, /exports no callable operations/);
  assert.equal(emptySurface.servicesContract, null);

  const badSignature = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export async function parse(value: string): Promise<string> { return value; }`,
  });
  assert.ok(badSignature.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(badSignature.diagnostics));

  const extraDataBeforeEmit = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(a: Uint8Array, b: Uint8Array, emit: (chunk: Uint8Array) => void): Uint8Array { emit(b); return a; }`,
  });
  assert.ok(
    extraDataBeforeEmit.diagnostics.some((d) => d.id === "NS1067" && /more than one data parameter/.test(d.message)),
    JSON.stringify(extraDataBeforeEmit.diagnostics),
  );

  const badThrow = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { throw new Error("bad"); }`,
  });
  assert.ok(badThrow.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(badThrow.diagnostics));

  const badSharedThrow = checkFiles({
    "core.ts": serviceCore,
    "shared.ts": `export function fail(): Uint8Array { throw 1; }`,
    "services/feeds.ts": `import { fail } from "../shared.ts"; export function parse(): Uint8Array { return fail(); }`,
  });
  assert.ok(badSharedThrow.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(badSharedThrow.diagnostics));

  const taggedThrow = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { const detail: string = "payload is empty"; if (bytes.length === 0) throw { kind: "empty", message: detail }; return bytes; }`,
  });
  assert.equal(taggedThrow.ok, true, JSON.stringify(taggedThrow.diagnostics));

  const ambientStringMessage = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `import * as path from "node:path"; export function parse(bytes: Uint8Array): Uint8Array { throw { kind: "bad", message: path.basename("/tmp/feed") }; }`,
  });
  assert.equal(ambientStringMessage.ok, true, JSON.stringify(ambientStringMessage.diagnostics));

  const nonStringMessage = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { throw { kind: "bad", message: 42 }; }`,
  });
  assert.ok(nonStringMessage.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(nonStringMessage.diagnostics));

  const locallyCaughtThrow = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { try { throw { kind: "local", message: "caught" }; } catch { return bytes; } }`,
  });
  assert.ok(locallyCaughtThrow.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(locallyCaughtThrow.diagnostics));

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

  const reservedSharedCoreName = checkFiles({
    "core.ts": `${serviceCore}\nclass __nativeSdkTaggedError {}`,
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.ok(reservedSharedCoreName.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(reservedSharedCoreName.diagnostics));

  const defaultExport = checkFiles({
    "core.ts": serviceCore,
    "services/feeds.ts": `export default function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.ok(defaultExport.diagnostics.some((d) => d.id === "NS1067"), JSON.stringify(defaultExport.diagnostics));

  const unknown = checkFiles({
    "core.ts": serviceCore.replace("feeds.parse", "feeds.missing"),
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  const diagnostic = unknown.diagnostics.find((d) => d.id === "NS1067");
  assert.ok(diagnostic, JSON.stringify(unknown.diagnostics));
  assert.match(diagnostic.message, /services\.contract\.json/);

  const unknownHost = checkFiles({
    "core.ts": serviceCore.replace(
      `Cmd.request("feeds.parse", model.bytes, { key: "parse", ok: "parsed", err: "failed" })`,
      `Cmd.host("feeds.missing", model.bytes)`,
    ),
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  const hostDiagnostic = unknownHost.diagnostics.find((d) => d.id === "NS1067");
  assert.ok(hostDiagnostic, JSON.stringify(unknownHost.diagnostics));
  assert.match(hostDiagnostic.message, /services\.contract\.json/);

  const knownHost = checkFiles({
    "core.ts": serviceCore.replace(
      `Cmd.request("feeds.parse", model.bytes, { key: "parse", ok: "parsed", err: "failed" })`,
      `Cmd.host("feeds.parse", model.bytes)`,
    ),
    "services/feeds.ts": `export function parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.equal(knownHost.ok, true, JSON.stringify(knownHost.diagnostics));

  const dollarExport = checkFiles({
    "core.ts": serviceCore.replace("feeds.parse", "feeds.$parse"),
    "services/feeds.ts": `export function $parse(bytes: Uint8Array): Uint8Array { return bytes; }`,
  });
  assert.equal(dollarExport.ok, true, JSON.stringify(dollarExport.diagnostics));
  assert.equal(JSON.parse(dollarExport.servicesContract!).operations[0].name, "feeds.$parse");
});

test("service byte aliases resolve through legal shared modules", () => {
  const result = checkFiles({
    "core.ts": serviceCore,
    "shared.ts": `export type Bytes = Uint8Array;`,
    "services/feeds.ts": `
import type { Bytes } from "../shared.ts";
export function parse(bytes: Bytes): Bytes { return bytes; }
`,
  });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.deepEqual(
    JSON.parse(result.servicesContract!).operations.map((op: { name: string }) => op.name),
    ["feeds.parse"],
  );
});

test("incremental vendoring preserves prior package facts and lets explicit updates win", () => {
  const source = `.{
    .name = "fixture",
    .service_packages = .{
        .{ .name = "alpha", .version = "1.2.3", .content_hash = "${"a".repeat(64)}" },
        .{ .name = "@scope/beta", .version = "2.0.0", .content_hash = "${"b".repeat(64)}" },
    },
}`;
  assert.deepEqual(readServicePackages(source).map((entry: { name: string; version: string }) => `${entry.name}@${entry.version}`), [
    "alpha@1.2.3",
    "@scope/beta@2.0.0",
  ]);
  assert.deepEqual(mergePackageSpecs(source, ["gamma@3.0.0", "alpha@1.3.0"]), [
    "@scope/beta@2.0.0",
    "alpha@1.3.0",
    "gamma@3.0.0",
  ]);
  const replaced = replaceServicePackages(source, [
    { name: "alpha", version: "1.3.0", content_hash: "c".repeat(64) },
    { name: "gamma", version: "3.0.0", content_hash: "d".repeat(64) },
  ]);
  assert.deepEqual(readServicePackages(replaced).map((entry: { name: string; version: string }) => `${entry.name}@${entry.version}`), [
    "alpha@1.3.0",
    "gamma@3.0.0",
  ]);

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-vendor-replace-"));
  try {
    const vendor = path.join(root, "src", "services", "vendor");
    const stage = path.join(root, ".native", "vendor-stage");
    fs.mkdirSync(path.join(vendor, "stale"), { recursive: true });
    fs.writeFileSync(path.join(vendor, "stale", "old.js"), "old");
    fs.mkdirSync(path.join(stage, "fresh"), { recursive: true });
    fs.writeFileSync(path.join(stage, "fresh", "new.js"), "new");
    replaceVendorTree(vendor, stage);
    assert.equal(fs.existsSync(path.join(vendor, "stale")), false);
    assert.equal(fs.readFileSync(path.join(vendor, "fresh", "new.js"), "utf8"), "new");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("service staging lowers tagged throws across the service-host graph", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-stage-"));
  try {
    const src = path.join(root, "src");
    const out = path.join(root, "out");
    fs.mkdirSync(path.join(src, "services"), { recursive: true });
    fs.writeFileSync(path.join(src, "core.ts"), `export function untouched(): void { throw new Error("core"); }\n`);
    fs.writeFileSync(path.join(src, "shared.ts"), `export function sharedFailure(): Uint8Array { throw { kind: "shared", message: "shared failure" }; }\n`);
    fs.writeFileSync(path.join(src, "services", "feeds.ts"), `import * as fs from "node:fs";\nimport { sharedFailure } from "../shared.ts";\nexport function parse(bytes: Uint8Array): Uint8Array {\n  if (bytes.length === 1) return sharedFailure();\n  if (fs.existsSync(".")) throw { kind: "fixture", message: "requested" };\n  return bytes;\n}\n`);
    const hostMain = path.join(root, "service_host_main.ts");
    fs.writeFileSync(hostMain, "// host\n");
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "stage_external_services.mjs");
    const result = spawnSync(process.execPath, [script, "--src", src, "--host-main", hostMain, "--out", out], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const service = fs.readFileSync(path.join(out, "services", "feeds.ts"), "utf8");
    assert.match(service, /class __nativeSdkTaggedError extends Error/);
    assert.match(service, /readonly kind: string/);
    assert.match(service, /constructor\(kind: string, message: unknown\)/);
    assert.match(service, /super\(String\(message\)\)/);
    assert.match(service, /this\.kind = kind/);
    assert.match(service, /throw new __nativeSdkTaggedError\("fixture", "requested"\)/);
    const shared = fs.readFileSync(path.join(out, "shared.ts"), "utf8");
    assert.match(shared, /throw new __nativeSdkTaggedError\("shared", "shared failure"\)/);
    assert.equal(fs.readFileSync(path.join(out, "core.ts"), "utf8"), `export function untouched(): void { throw new Error("core"); }\n`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("service staging refuses tampered vendored package bytes", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-hash-"));
  try {
    const src = path.join(root, "src");
    const packageDir = path.join(src, "services", "vendor", "tiny-package");
    fs.mkdirSync(packageDir, { recursive: true });
    fs.writeFileSync(path.join(src, "core.ts"), "export const core = 1;\n");
    fs.writeFileSync(path.join(src, "services", "feeds.ts"), "export function parse(bytes: Uint8Array): Uint8Array { return bytes; }\n");
    fs.writeFileSync(path.join(packageDir, "package.json"), JSON.stringify({ name: "tiny-package", version: "1.0.0" }));
    fs.writeFileSync(path.join(packageDir, "index.js"), "export default 1;\n");
    const hostMain = path.join(root, "service_host_main.ts");
    fs.writeFileSync(hostMain, "// host\n");
    const contract = path.join(root, "services.contract.json");
    fs.writeFileSync(contract, JSON.stringify({ packages: [{ name: "tiny-package", version: "1.0.0", content_hash: "0".repeat(64) }] }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "stage_external_services.mjs");
    const result = spawnSync(process.execPath, [script, "--src", src, "--host-main", hostMain, "--contract", contract, "--out", path.join(root, "out")], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /hashes to [0-9a-f]{64}, expected 0{64}/);
    assert.match(result.stderr, /re-run native vendor or restore the checked-in package bytes/);
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
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.21" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--host-platform", "test-test-test",
      "--target-platform", "test-test-test",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /contract echoes scriptc 0\.0\.21, but packages\/core pins 0\.0\.29/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane refuses a macOS target on a non-macOS build host", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-target-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--host-platform", "x86_64-linux-gnu",
      "--target-platform", "aarch64-macos-none",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /compile on a macOS build host only/);
    assert.match(result.stderr, /aarch64-macos-none/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane refuses a pairing outside the compiler's build matrix", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-matrix-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "wasm32-wasi-musl",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /desktop targets the pinned compiler covers/);
    assert.match(result.stderr, /wasm32-wasi-musl/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane refuses executables for mobile targets and threads the NDK into Android archives", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-mobile-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "service_profile.json"), "{}\n");
    fs.writeFileSync(path.join(stage, "service_inproc_main.ts"), "export {};\n");
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const ndk = path.join(root, "ndk");
    fs.mkdirSync(ndk);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");

    // No child process exists on mobile: the executable lane refuses with
    // the in-process pointer before any compiler work.
    const exeResult = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "aarch64-linux-android",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(exeResult.status, 0);
    assert.match(exeResult.stderr, /library archives only/);
    assert.match(exeResult.stderr, /in-process carrier/);

    // The archive lane is admitted, keeps the compiler's own Android
    // spelling, and threads --android-ndk as ANDROID_NDK_ROOT.
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("mobile compile missing SCRIPTC_CC=zigcc"); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "aarch64-linux-android") { console.error("mobile compile got SCRIPTC_TARGET=" + process.env.SCRIPTC_TARGET); process.exit(9); }
if (!process.env.ANDROID_NDK_ROOT) { console.error("mobile compile missing ANDROID_NDK_ROOT"); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "android service archive bytes");
`);
    const archive = path.join(root, "libservices.a");
    const env = { ...process.env };
    delete env.SCRIPTC_CC;
    delete env.SCRIPTC_TARGET;
    delete env.ANDROID_NDK_ROOT;
    const archiveResult = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-archive", archive,
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "aarch64-linux-android",
      "--android-ndk", ndk,
      "--compiler-js", compiler,
    ], { encoding: "utf8", env });
    assert.equal(archiveResult.status, 0, `${archiveResult.stdout}${archiveResult.stderr}`);
    assert.equal(fs.readFileSync(archive, "utf8"), "android service archive bytes");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane refuses cross-target Windows MSVC before compiler work", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-msvc-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host.exe"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "x86_64-windows-msvc",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /cross-target Windows build/);
    assert.match(result.stderr, /x86_64-windows-gnu/);
    assert.doesNotMatch(result.stderr, /service compiler reports/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service archive lane preserves native Windows MSVC", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-msvc-native-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "service_profile.json"), "{}\n");
    fs.writeFileSync(path.join(stage, "service_inproc_main.ts"), "export {};\n");
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.env.SCRIPTC_CC !== undefined || process.env.SCRIPTC_TARGET !== undefined) { console.error("native compile received cross environment"); process.exit(9); }
fs.writeFileSync(process.argv[process.argv.indexOf("-o") + 1] + ".lib.a", "native msvc archive bytes");
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const output = path.join(root, "libservices.a");
    const env = { ...process.env };
    delete env.SCRIPTC_CC;
    delete env.SCRIPTC_TARGET;
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-archive", output,
      "--host-platform", "x86_64-windows-gnu",
      "--target-platform", "x86_64-windows-msvc",
      "--compiler-js", compiler,
    ], { encoding: "utf8", env });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(output, "utf8"), "native msvc archive bytes");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service archive lane refuses architectures outside the localized-object matrix", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-archive-matrix-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    for (const target of ["aarch64-windows-gnu", "riscv64-linux-musl"]) {
      const result = spawnSync(process.execPath, [
        script,
        "--stage", stage,
        "--manifest", path.join(root, "package.json"),
        "--contract", path.join(root, "services.contract.json"),
        "--out-archive", path.join(root, `${target}.a`),
        "--host-platform", "aarch64-macos-none",
        "--target-platform", target,
        "--compiler", process.execPath,
      ], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /cannot build a runtime-localized archive/);
      assert.match(result.stderr, new RegExp(target));
      assert.match(result.stderr, /cross-Linux x86_64\/aarch64 \(Android included\), native Windows x86_64, cross-Windows x86_64 GNU/);
      assert.match(result.stderr, /Use the child carrier/);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane cross-compiles an admitted pairing over the compiler's zig-cc lane", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({ compiler_version: "0.0.29" }));
    const compiler = path.join(root, "compiler.mjs");
    // The stub asserts the cross environment the lane must receive: the
    // zig-cc driver selection, the target triple, and the supplied zig's
    // directory at the front of PATH.
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("expected SCRIPTC_CC=zigcc, got " + process.env.SCRIPTC_CC); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "x86_64-windows-gnu") { console.error("expected SCRIPTC_TARGET=x86_64-windows-gnu, got " + process.env.SCRIPTC_TARGET); process.exit(9); }
if (!(process.env.PATH ?? "").startsWith(${JSON.stringify(path.join(root, "toolchain"))})) { console.error("zig directory missing from PATH front: " + process.env.PATH); process.exit(9); }
fs.writeFileSync(process.argv[process.argv.indexOf("-o") + 1], "cross exe bytes");
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const output = path.join(root, "service-host.exe");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", output,
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "x86_64-windows-gnu",
      "--zig-exe", path.join(root, "toolchain", "zig"),
      "--compiler-js", compiler,
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(output, "utf8"), "cross exe bytes");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane passes an explicit npm-static allowlist and preserves coverage refusals", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-static-refusal-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({
      compiler_version: "0.0.29",
      packages: [{ name: "dynamic-only", version: "1.0.0", content_hash: "a".repeat(64) }],
    }));
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
const at = process.argv.indexOf("--npm-static");
if (at < 0 || process.argv[at + 1] !== "dynamic-only" || process.argv.includes("auto") || process.argv.includes("--dynamic")) {
  console.error("wrong npm policy: " + process.argv.slice(2).join(" ")); process.exit(9);
}
console.error("SC-NPM-STATIC dynamic-only: static coverage 42%; dynamic island fallback required");
process.exit(7);
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", path.join(root, "service-host"),
      "--host-platform", "test-test-test",
      "--target-platform", "test-test-test",
      "--compiler-js", compiler,
    ], { encoding: "utf8" });
    assert.equal(result.status, 7, result.stderr);
    assert.match(result.stderr, /SC-NPM-STATIC dynamic-only: static coverage 42%; dynamic island fallback required/);
    assert.match(result.stderr, /does not clear scriptc's static tier/);
    assert.match(result.stderr, /never enables npm auto-fallback or --dynamic/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the service compile lane refuses a package whose successful coverage verdict is below 100%", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-partial-static-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    fs.writeFileSync(path.join(root, "services.contract.json"), JSON.stringify({
      compiler_version: "0.0.29",
      packages: [{ name: "partial-static", version: "1.0.0", content_hash: "b".repeat(64) }],
    }));
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.argv[2] === "coverage") {
  console.log("scriptc coverage service_host_main.ts\\n\\n  statements analyzed   10\\n  compile statically    8  (80%)\\n\\n  deferred to runtime   2 sites\\n      ×2  unsupported package calls  SC2020");
  process.exit(0);
}
const out = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(out, "build should not have run");
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_service_compiler.mjs");
    const output = path.join(root, "service-host");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--manifest", path.join(root, "package.json"),
      "--contract", path.join(root, "services.contract.json"),
      "--out-exe", output,
      "--host-platform", "test-test-test",
      "--target-platform", "test-test-test",
      "--compiler-js", compiler,
    ], { encoding: "utf8" });
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stdout, /compile statically\s+8\s+\(80%\)/);
    assert.match(result.stderr, /does not clear scriptc's static tier/);
    assert.equal(fs.existsSync(output), false, "the build must not run after partial static coverage");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
