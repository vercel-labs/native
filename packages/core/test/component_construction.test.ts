import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/component_construction.ts", import.meta.url), "utf8");
const { nscvConstructionPolicy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvConstructionPolicy };").toString("base64")}`);
const float = (bytes: Uint8Array, at: number) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getFloat32(at, true);
function element(kind: number, flags = 0) { const r = new Uint8Array(40); r.set([17, 0, kind, 0, flags]); return r; }
function final(kind = 26) { const r = new Uint8Array(592); r.set([17, 1, kind]); r.fill(255, 8, 15); return r; }
function builtin(kind: number) { const r = new Uint8Array(36); r.set([17, 3, kind, 255, 255]); return r; }
test("element spacing distinguishes absent padding from authored zero and keeps per-field defaults", () => {
  assert.equal(float(policy(element(18)), 8), 24);
  assert.equal(policy(element(18))[2], 1);
  assert.equal(float(policy(element(18, 4)), 8), 0);
  const r = element(18, 4), w = new DataView(r.buffer); w.setFloat32(28, 5, true);
  assert.equal(float(policy(r), 4), 5); assert.equal(float(policy(r), 8), 0);
  r[2] = 12; assert.equal(policy(r)[1], 2);
});
test("checked radios and definite versus resizable dimensions retain authored precedence", () => {
  const r = element(48, 1), w = new DataView(r.buffer);
  for (const [at, v] of [[8, 100], [12, 80], [16, 120], [20, 200], [32, 0.25]]) w.setFloat32(at!, v!, true);
  assert.equal(float(policy(r), 40), 1); assert.equal(float(policy(r), 24), 120); assert.equal(float(policy(r), 32), 100);
  r[2] = 16; assert.equal(float(policy(r), 32), 0); assert.equal(float(policy(r), 36), 0); assert.equal(float(policy(r), 24), 120);
});
test("construction copies authored float words and owns results after request mutation", () => {
  const r = final(), w = new DataView(r.buffer); w.setUint32(20, 1 | 64, true);
  const bits = [0x80000000, 0x7fc00037, 0x3eaaaaab, 0]; bits.forEach((v, i) => w.setUint32(24 + i * 4, v, true));
  w.setUint32(120, 0x80000000, true); r[8] = 1; r[14] = 1;
  const out = policy(r); assert.deepEqual(out.slice(8, 24), r.slice(24, 40)); assert.equal(new DataView(out.buffer).getUint32(104, true), 0x80000000);
  const saved = out.slice(); r.fill(255); assert.deepEqual(out, saved);
});
test("finalization merges all handler actions and preserves authored action bits", () => {
  const r = final(51), w = new DataView(r.buffer); w.setUint16(16, 1 | 64 | 128 | 512 | 1024, true); w.setUint16(18, 1023, true);
  assert.equal(new DataView(policy(r).buffer).getUint16(0, true), 2047); assert.equal(policy(r)[2], 8);
  r[2] = 26; r[3] = 2; r[4] = 2; assert.equal(policy(r)[2], 1 | 8);
  r[3] = 1; assert.equal(policy(r)[2], 2 | 8);
  r[2] = 57; r[4] = 4; assert.equal(policy(r)[2], 4 | 8);
});
test("named syntax tokens inherit missing palette entries while radius none remains zero", () => {
  const r = final(), w = new DataView(r.buffer); r[8] = 7; r[9] = 6; r[14] = 4;
  w.setFloat32(124 + 5 * 16, 0.75, true); w.setFloat32(124 + 4 * 16, 0.25, true); w.setFloat32(588, 99, true);
  const out = policy(r); assert.equal(float(out, 8), 0.75); assert.equal(float(out, 24), 0.25); assert.equal(float(out, 104), 0);
});
test("builtin zero sentinels remain distinct from nullable element padding", () => {
  const r = builtin(8), w = new DataView(r.buffer); w.setFloat32(24, 7, true);
  const out = policy(r); assert.equal(float(out, 8), 24); assert.equal(float(out, 24), 7); assert.equal(out[5], 1);
  w.setFloat32(8, 1, true); assert.equal(float(policy(r), 12), 0);
  const tabs = policy(builtin(27)); assert.equal(tabs[4], 2); assert.equal(tabs[5], 0);
  assert.equal(policy(builtin(6))[1], 1); assert.equal(policy(builtin(24))[2], 1); assert.equal(policy(builtin(29))[0], 32);
});
test("synthesized descriptors separate disabled selection identities from separators", () => {
  const r = new Uint8Array(24); r.set([17, 2, 1]);
  const disabled = policy(r); assert.equal(disabled[0], 41); assert.equal(disabled[1], 1); assert.equal(disabled[2], 0); assert.equal(disabled[22], 1);
  r[3] = 2 | 4; const separator = policy(r); assert.equal(separator[0], 53); assert.equal(separator[1], 0); assert.equal(separator[22], 0);
  r[2] = 2; r[3] = 8; assert.equal(float(policy(r), 8), 0); assert.equal(new TextDecoder().decode(policy(r).slice(24)), "Context menu");
  r[3] = 0; assert.equal(float(policy(r), 8), 4);
});
test("each construction operation refuses all truncations and invalid masks", () => {
  for (const r of [element(18), final(), new Uint8Array([17, 2, 0, 0, ...new Array(20).fill(0)]), builtin(0)]) {
    for (let n = 0; n < r.length; n++) assert.throws(() => policy(r.slice(0, n)));
    assert.throws(() => policy(new Uint8Array([...r, 0])));
  }
  const r = final(); new DataView(r.buffer).setUint16(18, 1024, true); assert.throws(() => policy(r));
  const e = element(63); assert.throws(() => policy(e));
});
