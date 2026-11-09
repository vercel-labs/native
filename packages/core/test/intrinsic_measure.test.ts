import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "widget_metrics.ts", "intrinsic_measure.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvIntrinsicMeasure: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvIntrinsicMeasure};").toString("base64")}`);
function packet(kind: number, count = 0): Uint8Array {
  const b = new Uint8Array(288 + count * 44), w = new DataView(b.buffer);
  b.set([33, 1]); w.setUint32(8, 32, true); w.setUint32(12, count, true); b.set([32, 1, 32, 0, 0, 1, 0, kind], 64);
  for (const [at, v] of [[20, 14], [24, 13], [28, 14], [40, 24], [44, 28], [48, 32], [52, 36], [56, 10], [60, 10], [64, 10], [88, 2], [108, 8], [112, 12], [116, 16], [120, 4], [124, 2]]) w.setFloat32(64 + at!, v!, true);
  w.setFloat32(56, 24, true);
  for (let i = 0; i < count; i++) w.setUint32(288 + i * 40, 1, true);
  return b;
}
const word = (b: Uint8Array, at: number) => new DataView(b.buffer).getUint32(at, true);
const value = (b: Uint8Array, at: number) => new DataView(b.buffer).getFloat32(at, true);
test("horizontal scrolling requests each child's intrinsic and wrapped measurement before the next", () => {
  const b = packet(6, 3), w = new DataView(b.buffer); b[3] = 8;
  w.setUint32(328, 0, true); // Out-of-flow child is never admitted.
  let out = derive(b); assert.equal(word(out, 4), 3); assert.equal(word(out, 8), 0);
  w.setFloat32(292, 42.125, true); w.setFloat32(296, 14, true); w.setUint32(408, 1, true);
  out = derive(b); assert.equal(word(out, 4), 4); assert.equal(word(out, 8), 0); assert.equal(value(out, 24), 42.125);
  w.setFloat32(324, 35.25, true); w.setUint32(408, 3, true);
  out = derive(b); assert.equal(word(out, 4), 3); assert.equal(word(out, 8), 2);
  w.setFloat32(372, 18, true); w.setFloat32(376, 20, true); w.setFloat32(404, 70.5, true); w.setUint32(416, 3, true);
  out = derive(b); assert.equal(word(out, 4), 0); assert.equal(value(out, 12), 0); assert.equal(value(out, 16), 70.5);
});
test("composed title measurement precedes children even for empty titles and capped traversal", () => {
  const b = packet(19, 1), w = new DataView(b.buffer);
  let out = derive(b); assert.equal(word(out, 4), 1); assert.equal(value(out, 20), 24);
  w.setUint32(16, 1, true); out = derive(b); assert.equal(word(out, 4), 3);
  w.setUint32(4, 32, true); out = derive(b); assert.equal(word(out, 4), 0); assert.equal(value(out, 12), 420); assert.equal(value(out, 16), 220);
});
test("depth virtualized scrolling and disclosure guards avoid child measurements", () => {
  for (const kind of [0, 1, 2, 3, 4, 5, 7, 14]) {
    const b = packet(kind, 2), w = new DataView(b.buffer); w.setUint32(4, 32, true);
    assert.equal(word(derive(b), 4), 0);
  }
  for (const kind of [3, 4, 5, 6, 7]) { const b = packet(kind, 2); b[3] = 1; assert.equal(word(derive(b), 4), 0); }
  const b = packet(14, 1); assert.equal(word(derive(b), 4), 0); b[3] = 4; assert.equal(word(derive(b), 4), 3);
});
test("results own complete zeroed records and never mutate borrowed requests", () => {
  const b = packet(2, 1), before = b.slice(), out = derive(b), copied = out.slice();
  assert.deepEqual(b, before); assert.deepEqual(out.subarray(12), new Uint8Array(20));
  b.fill(255); derive(packet(19)); assert.deepEqual(out, copied);
});
test("the both-NaN maximum fact preserves a signaling floor without changing one-NaN selection", () => {
  const b = packet(1, 1), w = new DataView(b.buffer);
  w.setUint32(328, 1, true); w.setFloat32(292, 42.125, true); w.setFloat32(296, 14, true);
  w.setUint32(252, 0x7f812345, true); w.setUint32(216, 0x7f812345, true);
  assert.equal(word(derive(b), 12), 0x7fc12345);
  b[2] = 1; assert.equal(word(derive(b), 12), 0x7f812345);
  w.setFloat32(216, 0, true); assert.equal(value(derive(b), 12), 42.125);
  // A target can choose a signaling argument and still quiet its word.
  b[72] = 16; b[2] = 0; assert.equal(word(derive(b), 12), 0x7fc12345);
  b[2] = 2; assert.equal(word(derive(b), 12), 0x7f812345);
});
test("malformed lengths enums status words and reserved bytes reject before measurement", () => {
  for (const at of [0, 1, 2, 3, 16, 60, 64, 65, 67, 68, 71, 73, 264]) {
    const b = packet(2); b[at] = 255; assert.throws(() => derive(b), /invalid/);
  }
  for (const status of [2, 4, 0xffffffff]) { const b = packet(2, 1); new DataView(b.buffer).setUint32(328, status, true); assert.throws(() => derive(b), /child/); }
  assert.throws(() => derive(new Uint8Array(287)), /header/);
  const b = packet(2, 1); new DataView(b.buffer).setUint32(12, 0xffffffff, true); assert.throws(() => derive(b), /shape/);
  assert.throws(() => derive(packet(31)), /container/);
});
