import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { wyhash } from "../src/wyhash.ts";
const source = ["runtime_policy", "control_appearance", "control_primitives"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvControlPrimitives: primitive, nscvControlVectors: vector } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvControlPrimitives,nscvControlVectors};").toString("base64")}`);
const mask = (1n << 64n) - 1n;
function identity(op: number, a: bigint, b: bigint, c = 0n): Uint8Array {
  const bytes = new Uint8Array(32), w = new DataView(bytes.buffer); bytes.set([47, op, 1]);
  w.setBigUint64(8, a, true); w.setBigUint64(16, b, true); w.setBigUint64(24, c, true); return bytes;
}
function readId(bytes: Uint8Array): bigint { return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(0, true); }
test("primitive identities keep every u64 bit with wrapping and zero fallback", () => {
  const values = [0n, 1n, 0xffffffffn, 0x100000000n, 0x1000000000000000n, 0x8000000000000000n, mask];
  for (const id of values) for (const slot of values) {
    const out = primitive(identity(0, id, slot)), part = (id * 16n + slot) & mask;
    assert.equal(readId(out), id === 0n ? 0n : part === 0n ? id : part);
  }
});
test("selected glyph identities match independent full Wyhash and own results", () => {
  const seeds = [0n, mask, 0x5eed59a200000005n, 0x5eed59a200000006n];
  for (const seed of seeds) for (let i = 0n; i < 200n; i++) {
    const id = (i * 0x9e3779b97f4a7c15n) & mask, ordinal = (i * 0xd6e8feb86659fd93n) & mask;
    const request = identity(1, seed, id, ordinal), saved = request.slice(), out = primitive(request), expected = wyhash(seed, request.slice(16));
    assert.equal(readId(out), expected === 0n ? 1n : expected); assert.deepEqual(request, saved);
    request.fill(255); assert.equal(readId(out), expected === 0n ? 1n : expected);
  }
});
function radius(kind: number, size: number, flags: number, values: number[]): number {
  const b = new Uint8Array(40), w = new DataView(b.buffer); b.set([47, 2, 1, kind, size, 0, 0, flags]);
  values.forEach((value, i) => w.setFloat32(8 + i * 4, value, true)); return new DataView(primitive(b).buffer).getFloat32(0, true);
}
test("radius presence and tab register retain distinct size precedence", () => {
  for (let size = 0; size < 6; size++) {
    const step = size === 1 ? -2 : size === 2 ? 2 : 0;
    assert.equal(radius(0, size, 0, [9, 8, 7, 6, 5, 3]), 7);
    assert.equal(radius(0, size, 1, [9, 8, 7, 6, 5, 3]), 9);
    assert.equal(radius(0, size, 2, [9, 8, 7, 6, 5, 3]), 8 + step);
    assert.equal(radius(1, size, 4, [9, 8, 7, 6, 5, 3]), 0);
    assert.equal(radius(1, size, 6, [9, 8, 7, 6, 5, 3]), 8 + step);
    assert.equal(radius(1, size, 16, [9, 8, 7, 6, 5, 3]), Math.max(0, 6 + step - 3));
  }
});
test("radius plans consume copied appearance results without reapplying its policy", () => {
  for (const word of [0xc1200000, 0x80000000, 0, 0x41a20000, 0x7fc12345, 0x7f812345]) for (let size = 0; size < 6; size++) {
    for (const presence of [1, 2, 3]) {
      const b = new Uint8Array(40), w = new DataView(b.buffer); b.set([47, 2, 1, 0, size, 0, 0, presence | 8]);
      w.setFloat32(8, 7.25, true); w.setFloat32(12, 9.5, true); w.setFloat32(16, 12.5, true); w.setUint32(32, word, true);
      const out = primitive(b); assert.equal(new DataView(out.buffer).getUint32(0, true), word);
      b.fill(255); assert.equal(new DataView(out.buffer).getUint32(0, true), word);
    }
    const b = new Uint8Array(40), w = new DataView(b.buffer); b.set([47, 2, 1, 1, size, 0, 0, 10]);
    w.setFloat32(12, 9.5, true); w.setFloat32(28, 3, true); w.setUint32(32, word, true);
    const value = w.getFloat32(32, true);
    assert.equal(new DataView(primitive(b).buffer).getFloat32(0, true), Number.isNaN(value) ? 0 : Math.max(0, value));
    b[7] = 8;
    assert.equal(new DataView(primitive(b).buffer).getFloat32(0, true), Number.isNaN(value) ? 0 : Math.max(0, Math.fround(value - 3)));
    b[7] = 9; w.setFloat32(8, 7.25, true);
    assert.equal(new DataView(primitive(b).buffer).getFloat32(0, true), 7.25);
    b[7] = 12; assert.equal(new DataView(primitive(b).buffer).getFloat32(0, true), 0);
  }
});
function paint(phase: number): Uint8Array {
  const b = new Uint8Array(96), w = new DataView(b.buffer); b.set([48, 1, 1, 1, 2, 1, 1, phase]);
  w.setBigUint64(8, mask, true); w.setBigUint64(16, 3n, true); w.setBigUint64(24, 2n, true);
  for (let i = 32; i < 80; i += 4) w.setUint32(i, i % 16 === 0 ? 0x7f812345 : i % 16 === 4 ? 0x80000000 : 0x3f000000, true);
  w.setFloat32(80, 1.25, true); return b;
}
test("vector paint phases preserve raw styles ids and sequential overflow", () => {
  for (const phase of [0, 1]) {
    const b = paint(phase), out = vector(b), w = new DataView(out.buffer), saved = b.slice();
    assert.equal(w.getUint32(4, true), phase === 0 ? 1 : 2); assert.deepEqual(out.slice(phase === 0 ? 24 : 40, phase === 0 ? 40 : 56), b.slice(phase === 0 ? 32 : 64, phase === 0 ? 48 : 80));
    assert.equal(w.getBigUint64(phase === 0 ? 8 : 16, true), (mask * 16n + 7n + BigInt(phase)) & mask);
    assert.deepEqual(b, saved); b.fill(255); assert.deepEqual(out.slice(phase === 0 ? 24 : 40, phase === 0 ? 40 : 56), saved.slice(phase === 0 ? 32 : 64, phase === 0 ? 48 : 80));
  }
  const b = paint(0), w = new DataView(b.buffer); w.setBigUint64(16, mask, true); w.setBigUint64(24, 0n, true);
  assert.equal(new DataView(vector(b).buffer).getUint32(4, true), 1); b[7] = 1; assert.throws(() => vector(b), /overflow/);
  b[6] = 0; assert.equal(new DataView(vector(b).buffer).getBigUint64(16, true), 0xfffffffffffffff0n);
});
test("vector contain plans normalize center invert and reject degenerate scales", () => {
  const b = new Uint8Array(64), w = new DataView(b.buffer); b.set([48, 0, 1]);
  [10, 20, -40, 30, 1, 2, 20, 20].forEach((v, i) => w.setFloat32(8 + i * 4, v, true));
  const out = vector(b), r = new DataView(out.buffer); assert.equal(r.getUint32(4, true), 1);
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => r.getFloat32(8 + i * 4, true)), [1.5, 0, 0, 1.5, -26.5, 17]);
  assert.ok(Object.is(r.getFloat32(36, true), -0)); assert.ok(Object.is(r.getFloat32(40, true), -0));
  w.setFloat32(16, 0, true); assert.equal(new DataView(vector(b).buffer).getUint32(4, true), 0);
});
test("primitive packets reject malformed headers lengths and reserved tails", () => {
  for (const at of [0, 1, 2, 3, 7, 24, 31]) { const b = identity(0, 1n, 2n); b[at] = 255; assert.throws(() => primitive(b), /invalid/); }
  assert.throws(() => primitive(new Uint8Array(31)), /invalid/);
  const radius = new Uint8Array(40); radius.set([47, 2, 1]);
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 36, 39]) { const b = radius.slice(); b[at] = 255; assert.throws(() => primitive(b), /invalid/); }
  assert.throws(() => primitive(radius.slice(0, 39)), /invalid/);
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 84, 95]) { const b = paint(0); b[at] = 255; assert.throws(() => vector(b), /invalid/); }
});
