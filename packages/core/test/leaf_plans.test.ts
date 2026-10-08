import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "control_primitives", "leaf_plans"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvLeafPlans: leaf } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvLeafPlans};").toString("base64")}`);
function program(family: number, phase: number, flags: number, scalar = 0, id = 0xfedcba9876543210n): Uint8Array {
  const b = new Uint8Array(40), w = new DataView(b.buffer); b.set([49, 0, 1, family, phase, flags]);
  [1.25, 2.5, 80.25, 31.5, scalar].forEach((v, i) => w.setFloat32(8 + i * 4, v, true)); w.setBigUint64(28, id, true); return b;
}
function ops(b: Uint8Array): number[] { const r = leaf(b), w = new DataView(r.buffer); return Array.from({ length: w.getUint32(4, true) }, (_, i) => w.getUint32(8 + i * 16, true)); }
function geometry(op: number, frame: number[], values: number[], flags = 0): Uint8Array {
  const b = new Uint8Array(112), w = new DataView(b.buffer); b.set([49, 1, 1, op, 0, 0, flags]);
  frame.forEach((v, i) => w.setFloat32(8 + i * 4, v, true)); values.forEach((v, i) => w.setFloat32(24 + i * 4, v, true)); return b;
}
test("leaf command phases keep image clips avatar preference and lazy badge callback stages", () => {
  assert.deepEqual(ops(program(0, 0, 6)), [2, 3, 4]); assert.deepEqual(ops(program(0, 0, 0)), []);
  assert.deepEqual(ops(program(1, 0, 3)), [0, 2, 3, 4, 1]); assert.deepEqual(ops(program(1, 0, 1)), [0, 5, 1]);
  assert.deepEqual(ops(program(2, 0, 1)), [0, 6, 7]); assert.deepEqual(ops(program(2, 1, 0, 0)), []); assert.deepEqual(ops(program(2, 1, 0, 0.25)), [1]);
  assert.deepEqual(ops(program(2, 2, 8)), [8]); assert.deepEqual(ops(program(2, 2, 9)), [8, 5]);
  assert.deepEqual(ops(program(4, 0, 16)), [0, 9]); assert.deepEqual(ops(program(4, 0, 48)), [14, 9]); assert.deepEqual(ops(program(5, 0, 1)), [0, 10, 11]); assert.deepEqual(ops(program(9, 0, 4)), [2, 13, 4]);
  assert.deepEqual(ops(program(7, 0, 0, NaN)), [0]); assert.deepEqual(ops(program(7, 0, 0, -0)), []);
});
test("leaf plans own exact wrapping u64 identities and immutable results", () => {
  const mask = (1n << 64n) - 1n;
  for (const id of [0n, 1n, 0x1000000000000000n, mask]) {
    const b = program(1, 0, 2, 0, id), saved = b.slice(), r = leaf(b), w = new DataView(r.buffer);
    for (let i = 0; i < w.getUint32(4, true); i++) { const slot = BigInt(w.getUint32(12 + i * 16, true)), part = (id * 16n + slot) & mask; assert.equal(w.getBigUint64(16 + i * 16, true), id === 0n ? 0n : part === 0n ? id : part); }
    assert.deepEqual(b, saved); b.fill(255); assert.equal(w.getUint32(4, true), 5);
  }
});
test("leaf payloads preserve atlas sampling text bounds and asymmetric status padding", () => {
  const b = geometry(0, [1, 2, 30, 40], []), w = new DataView(b.buffer); w.setUint32(76, 1, true);
  assert.equal(new DataView(leaf(b).buffer).getUint32(68, true), 1); b[6] = 4; assert.equal(new DataView(leaf(b).buffer).getUint32(68, true), 0);
  const t = new DataView(leaf(geometry(1, [10, 20, 8, 32], [12, 5])).buffer);
  assert.equal(t.getFloat32(40, true), 15); assert.equal(t.getFloat32(56, true), 1); assert.equal(t.getFloat32(60, true), 15);
  const s = new DataView(leaf(geometry(6, [0, 0, 100, 32], [12, 0, 0, 0, 0])).buffer);
  assert.equal(s.getFloat32(8, true), 14); assert.equal(s.getFloat32(56, true), 72); assert.equal(s.getFloat32(60, true), 15);
  assert.equal(new DataView(leaf(geometry(6, [0, 0, 10, 10], [12, 0, 0, 0, 0])).buffer).getUint32(4, true), 0);
});
test("table row plans preserve source order hidden filtering exact parent and last visible omission", () => {
  const b = new Uint8Array(24 + 5 * 16), w = new DataView(b.buffer); b.set([49, 2, 1, 1]); w.setUint32(8, 5, true); w.setBigUint64(16, 0x100000000n, true);
  for (let i = 0; i < 5; i++) { w.setUint32(24 + i * 16, i === 1 ? 26 : 43, true); w.setUint32(28 + i * 16, i === 2 ? 1 : 0, true); w.setBigUint64(32 + i * 16, i === 3 ? 0n : 0x100000000n, true); }
  const r = leaf(b), v = new DataView(r.buffer); assert.equal(v.getUint32(4, true), 1); assert.equal(v.getUint32(8, true), 0); assert.ok(r.slice(12).every(x => x === 0));
  b[3] = 0; assert.equal(new DataView(leaf(b).buffer).getUint32(4, true), 2);
});
test("leaf packets reject malformed shapes flags phases tags and reserved tails", () => {
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 36, 39]) { const b = program(1, 0, 0); b[at] = 255; assert.throws(() => leaf(b), /invalid/); }
  assert.throws(() => leaf(program(0, 1, 0)), /invalid/);
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 80, 111]) { const b = geometry(1, [0, 0, 1, 1], []); b[at] = 255; assert.throws(() => leaf(b), /invalid/); }
  assert.throws(() => leaf(new Uint8Array(23)), /invalid/);
});
