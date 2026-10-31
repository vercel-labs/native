import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "control_primitives", "indicator_plans"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvIndicatorPlans: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvIndicatorPlans};").toString("base64")}`);
const bits = (x: number): number => { const w = new DataView(new ArrayBuffer(4)); w.setFloat32(0, x, true); return w.getUint32(0, true); };
const value = (x: number): number => { const w = new DataView(new ArrayBuffer(4)); w.setUint32(0, x, true); return w.getFloat32(0, true); };
function packet(mode = 0, style = 0, frame = [2.5, 3.25, 24.5, 20.75], spin = 0.3125): Uint8Array {
  const b = new Uint8Array(256), w = new DataView(b.buffer);
  b.set([51, mode, 1, 0, style, 0]); frame.forEach((x, i) => w.setFloat32(8 + i * 4, x, true));
  w.setFloat32(24, spin, true); w.setBigUint64(28, 0xfedcba9876543210n, true); w.setUint32(52, 12, true);
  [0.25, 0.1, 0.365, 0.15].forEach((x, i) => w.setFloat32(56 + i * 4, x, true)); w.setUint32(72, 300, true); w.setFloat32(80, 2, true);
  return b;
}
function render(b: Uint8Array, ink = [0.25, 0.5, 0.75, 0.875], stroke = 1.75): DataView {
  const first = new DataView(plan(b).buffer);
  if (first.getUint32(4, true) === 0) return first;
  assert.equal(first.getUint32(8, true), 0);
  const reply = b.slice(), w = new DataView(reply.buffer); reply[5] |= 1;
  ink.forEach((x, i) => w.setFloat32(36 + i * 4, x, true)); w.setFloat32(76, stroke, true);
  for (let i = 0; i < first.getUint32(16, true); i++) { const angle = first.getFloat32(40 + i * 4, true); w.setFloat32(96 + i * 8, Math.sin(angle), true); w.setFloat32(100 + i * 8, Math.cos(angle), true); }
  const out = new DataView(plan(reply).buffer); assert.equal(out.getUint32(4, true), 0); return out;
}
const verbs = (r: DataView, c: number): number[] => Array.from({ length: r.getUint32(40 + c * 256 + 12, true) }, (_, e) => r.getUint32(40 + c * 256 + 32 + e * 28, true));
test("arc spinner asks for appearance then emits one rounded stroke with copied identity", () => {
  const b = packet(), saved = b.slice(), query = new DataView(plan(b).buffer);
  assert.equal(query.getUint32(4, true), 1); assert.equal(query.getFloat32(12, true), Math.fround(Math.fround(20.75) * Math.fround(2 / 24)));
  assert.equal(query.getUint32(16, true), 9); assert.equal(query.getFloat32(40, true), Math.fround(Math.fround(-90 + 0.3125 * 360) * (0x8efa35 * 2 ** -29)));
  const r = render(b); assert.deepEqual(b, saved);
  assert.equal(r.getUint32(8, true), 1); assert.equal(r.getUint32(48, true), 1); assert.equal(r.getFloat32(12, true), 1.75);
  assert.equal(r.getBigUint64(40, true), (0xfedcba9876543210n * 16n + 2n) & 0xffffffffffffffffn);
  assert.deepEqual(verbs(r, 0), [0, 2, 2, 2, 2]); assert.equal(r.getFloat32(68, true), 0.875);
});
test("segmented spinner clamps counts and bakes the reduced-motion trail", () => {
  for (const [requested, expected] of [[0, 3], [12, 12], [99, 15]]) {
    const b = packet(0, 1), w = new DataView(b.buffer); w.setUint32(52, requested!, true); w.setUint32(72, 0, true); w.setFloat32(24, 0.5, true);
    const r = render(b); assert.equal(r.getUint32(8, true), expected);
    for (let c = 0; c < expected!; c++) {
      assert.deepEqual(verbs(r, c), [0, 1, 2, 2, 1, 2, 2, 3]); assert.equal(r.getUint32(40 + c * 256 + 8, true), 0);
      assert.equal(r.getBigUint64(40 + c * 256, true), (0xfedcba9876543210n * 16n + BigInt(1 + c)) & 0xffffffffffffffffn);
      assert.ok(r.getFloat32(40 + c * 256 + 28, true) <= 0.875);
    }
  }
  const segmented = new DataView(plan(packet(0, 1)).buffer); assert.equal(segmented.getUint32(16, true), 12); assert.equal(segmented.getFloat32(12, true), 0);
  const animated = render(packet(0, 1)); for (let c = 0; c < 12; c++) assert.equal(animated.getFloat32(40 + c * 256 + 28, true), 0.875);
});
test("indicator anchors snap the painted center and wrap u64 command identities", () => {
  const b = packet(1, 1, [1.3, 2.7, 10.1, 9.9]), w = new DataView(b.buffer); b[5] = 2; w.setBigUint64(28, 0xffffffffffffffffn, true);
  const r = new DataView(plan(b).buffer); assert.equal(r.getUint32(16, true), 12);
  assert.equal(r.getFloat32(20, true), 6.5); assert.equal(r.getFloat32(24, true), 7.5);
  assert.equal(r.getBigUint64(28, true), 0xfffffffffffffff2n); assert.equal(r.getBigUint64(40, true), 0xfffffffffffffff1n);
  w.setBigUint64(28, 0n, true); const zero = new DataView(plan(b).buffer); assert.equal(zero.getBigUint64(28, true), 0n);
});
test("empty and degenerate spinners draw nothing and never query appearance", () => {
  for (const frame of [[0, 0, 0, 10], [0, 0, 10, -0], [5, 5, -0, -0]]) {
    const r = new DataView(plan(packet(0, 0, frame)).buffer); assert.equal(r.getUint32(4, true), 0); assert.equal(r.getUint32(8, true), 0);
  }
  // NaN extents are not empty under the native ordered comparison.
  assert.equal(new DataView(plan(packet(0, 0, [0, 0, NaN, -1])).buffer).getUint32(4, true), 1);
  const negative = render(packet(0, 0, [20, 20, -12, -16])); assert.equal(negative.getUint32(8, true), 1);
  const thin = packet(0, 1); new DataView(thin.buffer).setFloat32(60, 0, true); assert.equal(render(thin).getUint32(8, true), 0);
});
test("indicator packets reject invalid tags flags and reserved storage", () => {
  assert.throws(() => plan(new Uint8Array(255)), /invalid/);
  for (const [at, x] of [[0, 50], [1, 2], [2, 2], [3, 16], [4, 2], [5, 4], [6, 32], [7, 1], [84, 1], [95, 1], [224, 1], [255, 1]]) { const b = packet(); b[at!] = x!; assert.throws(() => plan(b), /invalid/); }
});
