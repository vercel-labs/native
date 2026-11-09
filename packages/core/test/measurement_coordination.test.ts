import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "widget_metrics.ts", "measurement_coordination.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvWrappedMeasure: wrapped, nscvAxisChildMeasure: axis, nscvSpanSubtree: spans, nscvAxisMeasure: coordinate } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvWrappedMeasure,nscvAxisChildMeasure,nscvSpanSubtree,nscvAxisMeasure};").toString("base64")}`);
const word = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(at, true);
const value = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset, b.byteLength).getFloat32(at, true);
function packet(kind: number, count = 0): Uint8Array {
  const b = new Uint8Array(288 + count * 32), w = new DataView(b.buffer);
  b.set([34, 1]); w.setUint32(4, count, true); w.setUint32(12, 32, true); w.setFloat32(16, 120, true);
  b.set([32, 1, 32, 0, 0, 1, 0, kind], 64);
  for (const [at, v] of [[20, 14], [24, 13], [28, 14], [40, 24], [44, 28], [48, 32], [52, 36], [56, 10], [60, 10], [64, 10], [88, 2], [108, 8], [112, 12], [116, 16], [120, 4], [124, 2]]) w.setFloat32(64 + at!, v!, true);
  for (let i = 0; i < count; i++) w.setUint32(288 + i * 32, 1, true);
  return b;
}
test("wrapped rows preserve separate ordered width and height passes", () => {
  const b = packet(1, 3), w = new DataView(b.buffer); w.setUint32(320, 0, true);
  let r = wrapped(b); assert.equal(word(r, 4), 3); assert.equal(word(r, 8), 0);
  w.setFloat32(296, 40, true); w.setUint32(304, 1, true);
  r = wrapped(b); assert.equal(word(r, 4), 3); assert.equal(word(r, 8), 2);
  w.setFloat32(360, 80, true); w.setUint32(368, 1, true);
  r = wrapped(b); assert.equal(word(r, 4), 5); assert.equal(word(r, 8), 0); assert.equal(value(r, 16), 40);
  w.setFloat32(300, 20, true); w.setUint32(304, 3, true);
  r = wrapped(b); assert.equal(word(r, 4), 5); assert.equal(word(r, 8), 2); assert.equal(value(r, 16), 80);
  w.setFloat32(364, 30, true); w.setUint32(368, 3, true);
  r = wrapped(b); assert.equal(word(r, 4), 0); assert.equal(value(r, 12), 30);
});
test("bubble width replies apply the thread cap before wrapped child measurement", () => {
  const b = packet(2, 1), w = new DataView(b.buffer); w.setUint32(288, 3, true);
  let r = wrapped(b); assert.equal(word(r, 4), 4); assert.equal(value(r, 16), 120);
  w.setFloat32(296, 200, true); w.setUint32(304, 1, true);
  r = wrapped(b); assert.equal(word(r, 4), 5); assert.equal(value(r, 16), Math.fround(120 * Math.fround(0.8)));
  w.setFloat32(308, 110, true); assert.equal(value(wrapped(b), 16), 110);
});
test("fallback and paragraph continuations preserve guards and bound only fallback intrinsic replies", () => {
  const b = packet(26), w = new DataView(b.buffer); w.setUint32(76, 4, true);
  assert.equal(word(wrapped(b), 4), 2);
  w.setFloat32(36, 37.25, true); w.setUint32(40, 2, true); assert.equal(value(wrapped(b), 12), 37.25);
  w.setUint32(8, 32, true); assert.equal(word(wrapped(b), 4), 1);
  w.setFloat32(32, 50, true); w.setFloat32(28, 40, true); w.setUint32(40, 3, true); assert.equal(value(wrapped(b), 12), 40);
  w.setUint32(40, 0, true); w.setFloat32(20, 30, true); assert.equal(word(wrapped(b), 4), 0); assert.equal(value(wrapped(b), 12), 30);
});
test("axis queries retain main before cross and separator orientation without combining measurements", () => {
  const b = new Uint8Array(80), w = new DataView(b.buffer); b.set([35, 1, 0, 4, 53]);
  let r = axis(b); assert.equal(word(r, 4), 1); assert.equal(word(r, 8), 1);
  w.setUint32(8, 1, true); w.setFloat32(52, 1.5, true);
  r = axis(b); assert.equal(word(r, 4), 2); assert.equal(word(r, 8), 0);
  w.setUint32(8, 3, true); w.setFloat32(56, 160, true);
  r = axis(b); assert.equal(word(r, 4), 0); assert.equal(value(r, 56), 1.5); assert.equal(value(r, 60), 160);
  b[4] = 12; b[3] = 15; assert.equal(word(axis(b), 16), 3);
  b[3] = 31; assert.equal(word(axis(b), 16), 7);
  b[5] = 4; assert.equal(word(axis(b), 16), 1);
  w.setFloat32(48, 1, true); w.setUint32(8, 0, true); assert.equal(word(axis(b), 4), 2);
});
test("span search stops at depth before paragraph detection and retains child order and first-match stopping", () => {
  const b = new Uint8Array(28), w = new DataView(b.buffer); b.set([36, 1, 2, 1]); w.setUint32(8, 32, true); w.setUint32(12, 3, true);
  assert.equal(word(spans(b), 8), 0);
  w.setUint32(16, 1, true); assert.equal(word(spans(b), 8), 1);
  w.setUint32(20, 2, true); assert.equal(word(spans(b), 4), 0); assert.equal(word(spans(b), 12), 1);
  b[2] = 26; w.setUint32(4, 32, true); assert.equal(word(spans(b), 12), 0);
  w.setUint32(4, 31, true); assert.equal(word(spans(b), 12), 1);
});
test("all continuation records own their bytes and leave borrowed requests unchanged", () => {
  for (const [derive, b] of [[wrapped, packet(2, 1)], [axis, new Uint8Array([35, 1, ...new Uint8Array(78)])], [spans, new Uint8Array([36, 1, ...new Uint8Array(14)])]] as const) {
    const before = b.slice(), r = derive(b), saved = r.slice(); assert.deepEqual(b, before); b.fill(255); assert.deepEqual(r, saved);
  }
});
test("malformed packets reject lengths enums states reserved bytes and skipped-child replies", () => {
  for (const at of [0, 1, 2, 3, 40, 44, 64, 65, 66, 67, 68, 71, 73, 264, 288, 304, 316]) {
    const b = packet(2, 1); b[at] = 255; assert.throws(() => wrapped(b), /invalid/);
  }
  const b = packet(2, 1), w = new DataView(b.buffer); w.setUint32(288, 0, true); w.setUint32(304, 1, true); assert.throws(() => wrapped(b), /child/);
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 60, 79]) { const b = new Uint8Array(80); b.set([35, 1]); b[at] = 255; assert.throws(() => axis(b), /invalid/); }
  assert.throws(() => spans(new Uint8Array(15)), /header/);
  const s = new Uint8Array(20); s.set([36, 1]); new DataView(s.buffer).setUint32(12, 1, true); s[16] = 3; assert.throws(() => spans(s), /child/);
  assert.throws(() => wrapped(new Uint8Array(287)), /header/);
});
function axisPacket(count = 2): Uint8Array {
  const b = new Uint8Array(64 + count * 64), w = new DataView(b.buffer);
  b.set([37, 1]); w.setUint32(4, count, true); b.set([5, 0, 1, 0, 0], 16); w.setUint32(24, count, true);
  w.setFloat32(36, 120, true); w.setFloat32(40, 200, true);
  for (let i = 0; i < count; i++) w.setUint32(64 + i * 64, 1, true);
  return b;
}
test("axis coordination preserves preparation, first subtree pass, second subtree pass and width-aware heights", () => {
  const b = axisPacket(), w = new DataView(b.buffer);
  let r = coordinate(b); assert.equal(word(r, 4), 1); assert.equal(word(r, 8), 0);
  w.setUint32(112, 1, true); r = coordinate(b); assert.equal(word(r, 4), 2); assert.equal(word(r, 8), 0);
  w.setUint32(116, 1, true); w.setUint32(112, 3, true);
  r = coordinate(b); assert.equal(word(r, 4), 1); assert.equal(word(r, 8), 1);
  w.setUint32(176, 1, true); r = coordinate(b); assert.equal(word(r, 4), 2); assert.equal(word(r, 8), 1);
  w.setUint32(176, 3, true); r = coordinate(b); assert.equal(word(r, 4), 3); assert.equal(word(r, 8), 0);
  w.setUint32(120, 1, true); w.setUint32(112, 7, true);
  r = coordinate(b); assert.equal(word(r, 4), 4); assert.equal(word(r, 8), 0); assert.equal(value(r, 16), 120);
  w.setFloat32(124, 30, true); w.setUint32(112, 15, true);
  r = coordinate(b); assert.equal(word(r, 4), 3); assert.equal(word(r, 8), 1);
  w.setUint32(176, 7, true); r = coordinate(b); assert.equal(word(r, 4), 0);
  assert.equal(word(r, 32), 2); assert.equal(value(r, 56), 30);
});
test("axis coordination preserves the single pass for trees without spans and excludes NaN authored heights", () => {
  const b = axisPacket(1), w = new DataView(b.buffer); w.setUint32(112, 3, true);
  assert.equal(word(coordinate(b), 4), 0);
  w.setUint32(112, 1, true); w.setFloat32(72, NaN, true); assert.equal(word(coordinate(b), 4), 0);
  b[18] = 0; w.setFloat32(72, 0, true); assert.equal(word(coordinate(b), 4), 0);
});
test("axis coordination validates complete copied packets before issuing any query", () => {
  for (const at of [0, 1, 2, 3, 8, 12, 16, 17, 18, 19, 20, 21, 48, 52, 64, 112, 116, 120]) {
    const b = axisPacket(1); b[at] = 255; assert.throws(() => coordinate(b), /invalid/);
  }
  const b = axisPacket(1), copy = b.slice(), r = coordinate(b), saved = r.slice();
  assert.deepEqual(b, copy); b.fill(255); assert.deepEqual(r, saved);
});
