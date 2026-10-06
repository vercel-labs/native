// The compiler-truth pass: `native check`'s final verdict comes from the
// pinned external core compiler. Three outcomes, pinned: a well-typed
// core passes, a type error fails with the compiler's diagnostic, and
// the SDK declaration mapping resolves the package specifier.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "compiler_typecheck.mjs");

function run(source: string): { status: number | null; out: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ctc-"));
  const entry = path.join(dir, "core.ts");
  fs.writeFileSync(entry, source);
  const probe = spawnSync(process.execPath, [script, entry], { encoding: "utf8" });
  fs.rmSync(dir, { recursive: true, force: true });
  return { status: probe.status, out: `${probe.stdout ?? ""}${probe.stderr ?? ""}` };
}

const green = `import type { Cmd } from "@native-sdk/core";
export interface Model { count: number; }
export type Msg = { kind: "tick" };
export function init(): Model { return { count: 0 }; }
export function update(m: Model, msg: Msg): Model { return { count: m.count + 1 }; }
`;

test("a well-typed core passes the compiler-truth pass", () => {
  const r = run(green);
  assert.equal(r.status, 0, r.out);
});

test("a type error fails with the compiler's diagnostic", () => {
  const r = run(green.replace("{ count: 0 }", '{ count: "zero" }'));
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /TypeScript error|SC0001/);
});

test("an npm package outside the static tier fails check with the compiler note and Native SDK teaching", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ctc-npm-refusal-"));
  try {
    const entry = path.join(dir, "core.ts");
    const services = path.join(dir, "services");
    const vendor = path.join(services, "vendor", "dynamic-only");
    fs.mkdirSync(vendor, { recursive: true });
    fs.writeFileSync(entry, green);
    fs.writeFileSync(path.join(services, "probe.ts"), 'import probe from "dynamic-only";\nexport function run(): string { return probe("x"); }\n');
    fs.writeFileSync(path.join(vendor, "package.json"), JSON.stringify({
      name: "dynamic-only", version: "1.0.0", type: "module", types: "index.d.ts", exports: "./index.js",
    }));
    fs.writeFileSync(path.join(vendor, "index.d.ts"), "export default function probe(value: string): string;\n");
    // getCipherInfo is typed but has no static lowering in the pinned compiler.
    // The package itself remains marked "static" in coverage, so this pins
    // Native SDK's stricter requirement that the total be 100%.
    fs.writeFileSync(path.join(vendor, "index.js"), [
      'import { getCipherInfo } from "node:crypto";',
      "export default function probe(x) {",
      '  getCipherInfo("aes-256-cbc");',
      "  return x;",
      "}",
      "",
    ].join("\n"));
    const probe = spawnSync(process.execPath, [script, entry], { encoding: "utf8" });
    const out = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
    assert.equal(probe.status, 1, out);
    assert.match(out, /SC2020|deferred to runtime|compile statically/i);
    assert.match(out, /does not clear scriptc's static tier/);
    assert.match(out, /never enables npm auto-fallback or --dynamic/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("complete file and timer routes require every callback field and outcome", () => {
  const source = `
import { Cmd, asciiBytes, type FileResultArm, type TimerResultArm } from "@native-sdk/core";
export interface Model { readonly done: boolean; }
export type Msg = { readonly kind: "go" }
  | ({ readonly kind: "file" } & FileResultArm)
  | ({ readonly kind: "timer" } & TimerResultArm)
  | { readonly kind: "clock"; readonly stamp: Uint8Array };
export function initialModel(): Model { return { done: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  if (msg.kind !== "go") return { done: true };
  return [model, Cmd.batch([
    Cmd.readFileResult(asciiBytes("notes.txt"), { result: "file" }),
    Cmd.writeFileResult(asciiBytes("notes.txt"), asciiBytes("body"), { result: "file" }),
    Cmd.timerResult("save", 800, "one_shot", { result: "timer" }),
    Cmd.timerResult("refresh", 30000, "repeating", { result: "timer" }),
    Cmd.wallTime("clock"),
  ])];
}
`;
  let r = run(source); assert.equal(r.status, 0, r.out);
  r = run(source.replace('({ readonly kind: "file" } & FileResultArm)', '{ readonly kind: "file"; readonly bytes: Uint8Array }'));
  assert.equal(r.status, 1, r.out);
  r = run(source.replace('({ readonly kind: "timer" } & TimerResultArm)', '{ readonly kind: "timer"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: "fired" }'));
  assert.equal(r.status, 1, r.out);
  r = run(source.replace('readonly stamp: Uint8Array', 'readonly stamp: number'));
  assert.equal(r.status, 1, r.out);
});
