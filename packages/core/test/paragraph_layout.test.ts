import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "paragraph_layout"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvParagraphLayout: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvParagraphLayout};").toString("base64")}`);
function packet(text: string, width = 30, capacity = 160, first = 0): Uint8Array {
  const bytes = new TextEncoder().encode(text), data = 192 + 32 + 512 + capacity * 32;
  const b = new Uint8Array(data + bytes.length), w = new DataView(b.buffer);
  b.set([53, 0, 1, 1, 0, 0]);
  for (const [at, x] of [[8, 1], [12, capacity], [16, first], [20, data], [24, b.length], [40, 10], [192, data], [196, bytes.length]]) w.setUint32(at!, x!, true);
  w.setFloat32(32, 10, true); w.setFloat32(36, width, true); b.set(bytes, data); return b;
}
function layout(b: Uint8Array): { result: DataView; calls: number[][] } {
  const calls: number[][] = [];
  for (let n = 0; n < 10000; n++) {
    const before = b.slice(), out = plan(b); assert.deepEqual(b, before);
    const w = new DataView(out.buffer);
    if (out[7] === 2) return { result: w, calls };
    assert.equal(out[7], 1);
    const span = w.getUint32(128, true), start = w.getUint32(132, true), end = w.getUint32(136, true);
    calls.push([span, start, end]); w.setFloat32(140, (end - start) * 5, true); out[6] = 1; b = out;
  }
  throw new Error("continuation did not finish");
}
test("paragraphs break words, retain source offsets and request exact prefixes", () => {
  const { result: r, calls } = layout(packet("abc de"));
  assert.deepEqual(calls, [[0, 0, 3], [0, 3, 4], [0, 4, 6]]);
  assert.equal(r.getUint32(144, true), 1); assert.equal(r.getUint32(56, true), 1);
  assert.equal(r.getFloat32(68, true), 30); assert.equal(r.getUint32(736 + 8, true), 6);
  const small = layout(packet("abc de", 20)).result;
  assert.equal(small.getUint32(144, true), 2); assert.equal(small.getUint32(56, true), 2);
  assert.equal(small.getUint32(736 + 32 + 4, true), 4);
});
test("paragraph alignment, pages and truncation preserve complete extents", () => {
  const b = packet("abc\nde", 40); b[4] = 1;
  const r = layout(b).result;
  assert.equal(r.getFloat32(736 + 16, true), 12.5); assert.equal(r.getFloat32(736 + 32 + 16, true), 15);
  const page = layout(packet("abc\nde", 40, 160, 1)).result;
  assert.equal(page.getUint32(56, true), 1); assert.equal(page.getUint32(736 + 12, true), 1);
  assert.equal(page.getFloat32(148, true), 25);
  const empty = layout(packet("abc\nde", 40, 0)).result;
  assert.equal(empty.getUint32(56, true), 0); assert.equal(empty.getUint32(76, true), 1); assert.equal(empty.getFloat32(148, true), 25);
});
test("intrinsic paragraphs ignore CR presentation and carry lines across spans", () => {
  const b = packet("ab\r\ncd\ref"); b[1] = 1;
  const { result: r, calls } = layout(b);
  assert.deepEqual(calls, [[0, 0, 2], [0, 3, 3], [0, 4, 6], [0, 7, 9]]);
  assert.equal(r.getFloat32(68, true), 20);
});
test("paragraph packets refuse malformed storage, spans and missing replies", () => {
  assert.throws(() => plan(new Uint8Array(191)), /invalid/);
  for (const [at, x] of [[0, 52], [1, 2], [2, 2], [3, 3], [4, 3], [6, 2], [7, 3], [208, 2], [216, 1]]) {
    const b = packet("text"); b[at!] = x!; assert.throws(() => plan(b), /invalid/);
  }
  const query = plan(packet("text")); assert.throws(() => plan(query), /reply missing/);
  const bad = packet("text"); new DataView(bad.buffer).setUint32(196, 9999, true); assert.throws(() => plan(bad), /invalid/);
});
test("paragraph replies reject corrupt cursors pieces runs and initial state", () => {
  for (const at of [44, 96, 172, 224]) {
    const b = packet("a b"); b[at] = 1; assert.throws(() => plan(b), /invalid/);
  }
  const reply = plan(packet("a b")); reply[6] = 1;
  for (const [at, x] of [[40, 5], [44, 2], [48, 4], [100, 2], [104, 4], [112, 33], [128, 1], [132, 1], [144, 1], [152, 2], [172, 1]]) {
    const b = reply.slice(); new DataView(b.buffer).setUint32(at!, x!, true); assert.throws(() => plan(b), /invalid/);
  }
  const placed = plan(reply); placed[6] = 1;
  for (const [at, x] of [[56, 161], [60, 2], [84, 1], [88, 4], [96, 33], [224, 1], [232, 4], [736, 1], [744, 0], [748, 129], [764, 1]]) {
    const b = placed.slice(); new DataView(b.buffer).setUint32(at!, x!, true); assert.throws(() => plan(b), /invalid/, String(at));
  }
});
