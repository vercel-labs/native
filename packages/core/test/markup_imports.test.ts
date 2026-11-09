import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_imports.ts", import.meta.url), "utf8");
const { nscvMarkupImports: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupImports };").toString("base64")}`);
const bytes = (s: string): Uint8Array => new TextEncoder().encode(s);
function request(stage: number, fields: readonly (number | string | Uint8Array)[]): Uint8Array {
  const parts = fields.map(field => {
    const blob = typeof field === "number" ? null : typeof field === "string" ? bytes(field) : field;
    const out = new Uint8Array(8 + (blob?.length ?? 0));
    new DataView(out.buffer).setFloat64(0, blob ? blob.length : field as number, true);
    if (blob) out.set(blob, 8);
    return out;
  });
  const out = new Uint8Array(4 + parts.reduce((n, p) => n + p.length, 0)); out.set([108, 1, stage, 0]);
  let at = 4; for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
function result(stage: number, fields: readonly (number | string | Uint8Array)[]) {
  const out: Uint8Array = run(request(stage, fields)), view = new DataView(out.buffer, out.byteOffset, out.byteLength);
  assert.deepEqual(Array.from(out.subarray(0, 3)), [108, 1, stage]);
  assert.deepEqual(Array.from(out.subarray(4, 8)), [0, 0, 0, 0]);
  return { action: out[3], a: view.getFloat64(8, true), b: view.getFloat64(16, true), c: view.getFloat64(24, true), payload: out.subarray(32) };
}
function chunks(payload: Uint8Array): Uint8Array[] {
  let at = 0; const out: Uint8Array[] = [];
  while (at < payload.length) {
    const length = new DataView(payload.buffer, payload.byteOffset + at, 8).getFloat64(0, true); at += 8;
    out.push(payload.subarray(at, at + length)); at += length;
  }
  assert.equal(at, payload.length); return out;
}
test("runtime imports retain validation precedence first src and raw path bytes", () => {
  const path = (attrs: readonly (string | Uint8Array)[], children = 0, capacity = 200) => result(0, ["src", "src/app.native", capacity, children, attrs.length / 2, ...attrs]);
  assert.equal(path(["unknown", ""], 1).action, 3);
  assert.deepEqual([path(["src", ""]).action, path(["src", ""]).a], [2, 3]);
  assert.equal(path(["src", "a.native", "src", "bad.txt"]).a, 7);
  assert.deepEqual(path(["src", "a.native", "src", "b.native"]).payload, bytes("src/a.native"));
  assert.equal(path(["src", "../escape.native"]).a, 8);
  assert.equal(path(["src", "./a.native"], 0, 11).a, 4);
  assert.deepEqual(path(["src", "./a.native"], 0, 12).payload, bytes("src/a.native"));
  const raw = Uint8Array.of(255, 0, ...bytes(".native"));
  assert.deepEqual(path(["src", raw]).payload, Uint8Array.of(...bytes("src/"), ...raw));
});
test("runtime imports detect last ancestor cycles before dedupe and depth before count", () => {
  const cycle = result(1, ["same.native", 2, 32, 3, "same.native", "middle.native", "same.native", 1, "same.native"]);
  assert.equal(cycle.action, 5); assert.equal(cycle.a, 4);
  assert.equal(new TextDecoder().decode(Buffer.concat(chunks(cycle.payload))), "import cycle: same.native -> same.native");
  assert.equal(result(1, ["seen.native", 7, 32, 8, ...Array(8).fill("other.native"), 1, "seen.native"]).action, 6);
  const depth = result(1, ["new.native", 7, 32, 8, ...Array(8).fill("other.native"), 0]);
  assert.deepEqual([depth.action, depth.a], [1, 9]);
  assert.deepEqual([result(1, ["new.native", 0, 32, 1, "app.native", 0]).action, result(1, ["new.native", 0, 32, 1, "app.native", 0]).a], [8, 33]);
});
test("runtime imports order visits and preserve document-wide template diagnostics", () => {
  const step = (fields: number[]) => { const r = result(2, fields); return [r.action, r.a, r.b, r.c]; };
  assert.deepEqual(step([0, 0, 2, 1, 1, 0]), [9, 0, 0, 1]);
  assert.deepEqual(step([0, 2, 2, 1, 1, 0]), [10, 0, 1, 1]);
  assert.deepEqual(step([1, 1, 2, 1, 1, 1]), [11, 12, 0, 0]);
  assert.deepEqual(step([1, 1, 2, 1, 0, 1]), [13, 0, 0, 0]);
  const duplicate = result(3, [2, 1, "card", 1, "card", "first.native", "2", "8", 1, "card", "second.native", "4", "9"]);
  assert.equal(duplicate.action, 15);
  assert.equal(duplicate.a, 9);
  assert.equal(new TextDecoder().decode(Buffer.concat(chunks(duplicate.payload))), 'duplicate template name "card" - also defined at first.native:2:8; template names are document-wide once imports resolve, so rename one (imports never shadow silently)');
  const missing = result(4, ["missing.native"]);
  assert.equal(missing.a, 3); assert.equal(missing.b, bytes('unable to read imported file "{s}"').length);
  assert.equal(new TextDecoder().decode(Buffer.concat(chunks(missing.payload))), 'unable to read imported file "missing.native"');
  const fields: (number | string)[] = [256, 1, "card"];
  for (let i = 0; i < 256; i++) fields.push(1, "card", "p.native", "1", "1");
  const limit = result(3, fields); assert.deepEqual([limit.action, limit.a], [1, 11]);
});
test("runtime import transport rejects truncated headers blobs words and inexact state", () => {
  const valid = request(0, ["src", "src/app.native", 200, 0, 1, "src", "a.native"]);
  for (let i = 0; i < valid.length; i++) assert.throws(() => run(valid.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = valid.slice(); bad[at] = 255; assert.throws(() => run(bad)); }
  for (const value of [-1, NaN, Infinity, 0.5, 2 ** 53]) {
    const bad = valid.slice(); new DataView(bad.buffer).setFloat64(4, value, true); assert.throws(() => run(bad));
  }
  assert.throws(() => run(Uint8Array.of(...valid, 0)));
  assert.throws(() => run(request(1, ["p.native", 0, 0, 2])));
  assert.throws(() => run(request(2, [3, 0, 0, 0, 0, 0])));
});
