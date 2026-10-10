import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkFiles } from "./helpers.ts";
import { checkFile } from "../src/frontend.ts";
import { analyzeSqlite, generateCoreSurface } from "../src/sqlite_codegen.ts";

const entry = `
import { step } from "./worker.ts";
export interface Model { readonly flag: boolean; }
export type Msg =
  | { readonly kind: "index"; readonly value: number }
  | { readonly kind: "gain"; readonly value: number };
export function initialModel(): Model { return { flag: false }; }
export function update(model: Model, msg: Msg): Model { return { flag: step(msg) }; }
`;
const worker = `
export type WorkerMsg =
  | { readonly kind: "index"; readonly value: number }
  | { readonly kind: "gain"; readonly value: number };
export function step(msg: WorkerMsg): boolean {
  switch (msg.kind) {
    case "index": return new Uint8Array([1, 2])[msg.value] === 1;
    case "gain": return msg.value > 0.5;
  }
}
`;

function contract(files: Record<string, string>): any {
  const result = checkFiles(files, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, [...result.typeErrors, ...result.diagnostics.map(d => `${d.id}: ${d.message}`)].join("\n"));
  return JSON.parse(result.contract!);
}

test("checked SQLite row forwarding preserves complete identifier and timestamp integer ABI", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const app = path.resolve(packageDir, "../../examples/relational-notes/src");
  const sdk = fs.mkdtempSync(path.join(os.tmpdir(), "native-row-forwarding-"));
  try {
    const analysis = analyzeSqlite(app);
    assert.deepEqual(analysis.diagnostics, []);
    fs.cpSync(path.join(packageDir, "sdk"), sdk, { recursive: true });
    const sdkCorePath = path.join(sdk, "core.ts");
    fs.writeFileSync(sdkCorePath, generateCoreSurface(fs.readFileSync(sdkCorePath, "utf8"), analysis));
    const result = checkFile(path.join(app, "core.ts"), { sdkCorePath, contractEntry: "src/core.ts" });
    assert.equal(result.ok, true, [...result.typeErrors, ...result.diagnostics.map(d => `${d.id}: ${d.message}`)].join("\n"));
    const doc = JSON.parse(result.contract!);
    const row = doc.types.structs.find((s: any) => s.name === "NoteRow");
    assert.deepEqual(row.fields.map((f: any) => [f.name, f.type.kind]), [["id", "i64"], ["title", "bytes"], ["updated_at", "i64"]]);
  } finally {
    fs.rmSync(sdk, { recursive: true, force: true });
  }
});

test("whole message forwarding carries integer demand through matching union arms", () => {
  const doc = contract({ "core.ts": entry, "worker.ts": worker });
  assert.equal(doc.msg.arms.find((a: any) => a.name === "index").payload.class, "i64");
  assert.equal(doc.msg.arms.find((a: any) => a.name === "gain").payload.class, "f64");
});

test("narrowed namespace forwarding does not connect unrelated union arms", () => {
  const source = entry.replace('import { step }', 'import * as worker')
    .replace('return { flag: step(msg) };', 'return { flag: msg.kind === "index" ? worker.step(msg) : msg.value > 0.5 };');
  const doc = contract({ "core.ts": source, "worker.ts": worker });
  assert.equal(doc.msg.arms.find((a: any) => a.name === "index").payload.class, "i64");
  assert.equal(doc.msg.arms.find((a: any) => a.name === "gain").payload.class, "f64");
});

test("structured forwarding connects nested optional records and record arrays by declaration", () => {
  const doc = contract({
    "core.ts": `
      import { step } from "./worker.ts";
      export interface InputLeaf { readonly index: number; readonly offset: number; }
      export interface Input { readonly maybe: InputLeaf | null; readonly rows: readonly InputLeaf[]; }
      export interface Model { readonly flag: boolean; }
      export type Msg = { readonly kind: "run"; readonly input: Input } | { readonly kind: "noop" };
      export function initialModel(): Model { return { flag: false }; }
      export function update(model: Model, msg: Msg): Model {
        return msg.kind === "run" ? { flag: step(msg.input) } : model;
      }`,
    "worker.ts": `
      interface Leaf { readonly index: number; readonly offset: number; }
      interface InputArg { readonly maybe: Leaf | null; readonly rows: readonly Leaf[]; }
      export function step(input: InputArg): boolean {
        const bytes = new Uint8Array([1, 2]);
        return input.maybe !== null && bytes[input.maybe.index] === 1 &&
          input.rows.some(row => bytes[row.index] === 1 && row.offset > 0.5);
      }`,
  });
  const leaf = doc.types.structs.find((s: any) => s.name === "InputLeaf");
  assert.equal(leaf.fields.find((f: any) => f.name === "index").type.kind, "i64");
  assert.equal(leaf.fields.find((f: any) => f.name === "offset").type.kind, "f64");
});

test("fractional record input meeting a callee index demand is a taught conflict", () => {
  const result = checkFiles({
    "core.ts": `
      import { step } from "./worker.ts";
      interface Fraction { readonly value: number; }
      export interface Model { readonly flag: boolean; }
      export type Msg = { readonly kind: "run" } | { readonly kind: "noop" };
      export function initialModel(): Model { return { flag: false }; }
      export function update(model: Model, msg: Msg): Model {
        const input: Fraction = { value: 0.5 };
        return { flag: step(input) };
      }`,
    "worker.ts": `
      interface IndexArg { readonly value: number; }
      export function step(input: IndexArg): boolean { return new Uint8Array([1, 2])[input.value] === 1; }`,
  });
  assert.equal(result.typeErrors.length, 0);
  assert.ok(result.diagnostics.some(d => d.id === "NS1016"), "fractional forwarding must not silently specialize to i64");
});

test("retyped locals preserve the complete structured argument flow", () => {
  const source = entry.replace('import { step }', 'import { step, type WorkerMsg }')
    .replace('return { flag: step(msg) };', 'const forwarded: WorkerMsg = msg; return { flag: step(forwarded) };');
  const doc = contract({ "core.ts": source, "worker.ts": worker });
  assert.equal(doc.msg.arms.find((a: any) => a.name === "index").payload.class, "i64");
  assert.equal(doc.msg.arms.find((a: any) => a.name === "gain").payload.class, "f64");
});

test("comparison-only demands yield through a forwarded host-number record", () => {
  const doc = contract({
    "core.ts": `
      import { step } from "./worker.ts";
      interface HostInput { readonly value: number; }
      export interface Model { readonly flag: boolean; }
      export type Msg = { readonly kind: "run" } | { readonly kind: "noop" };
      export function initialModel(): Model { return { flag: false }; }
      export function update(model: Model, msg: Msg): Model { return model; }
      export function passes(model: Model, value: number): boolean {
        const input: HostInput = { value };
        return step(input);
      }`,
    "worker.ts": `
      interface ComparedInput { readonly value: number; }
      export function step(input: ComparedInput): boolean { return input.value === 0; }`,
  });
  assert.equal(doc.model_helpers.find((h: any) => h.name === "passes").params[0].kind, "f64");
});

test("constructor and method arguments carry nested integer requirements", () => {
  const doc = contract({
    "core.ts": `
      import { Reader } from "./worker.ts";
      export interface ReadInput { readonly value: number; }
      export interface Model { readonly flag: boolean; }
      export type Msg = { readonly kind: "run"; readonly input: ReadInput } | { readonly kind: "noop" };
      export function initialModel(): Model { return { flag: false }; }
      export function update(model: Model, msg: Msg): Model {
        if (msg.kind === "noop") return model;
        const reader = new Reader(msg.input);
        return { flag: reader.matches(msg.input) };
      }`,
    "worker.ts": `
      interface ConstructorInput { readonly value: number; }
      interface MethodInput { readonly value: number; }
      export class Reader {
        value: number;
        constructor(input: ConstructorInput) { this.value = input.value; }
        matches(input: MethodInput): boolean {
          return new Uint8Array([1, 2])[this.value] === new Uint8Array([1, 2])[input.value];
        }
      }`,
  });
  assert.equal(doc.types.structs.find((s: any) => s.name === "ReadInput").fields[0].type.kind, "i64");
});

test("literal union forwarding feeds only the selected arm", () => {
  const source = entry.replace('return { flag: step(msg) };',
    'return { flag: msg.kind === "index" ? step({ kind: "index", value: msg.value }) : step({ kind: "gain", value: msg.value }) };');
  const doc = contract({ "core.ts": source, "worker.ts": worker });
  assert.equal(doc.msg.arms.find((a: any) => a.name === "index").payload.class, "i64");
  assert.equal(doc.msg.arms.find((a: any) => a.name === "gain").payload.class, "f64");
});
