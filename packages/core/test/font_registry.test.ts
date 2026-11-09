import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "font_registry.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvFontRegistry: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvFontRegistry};").toString("base64")}`);
interface Query { id?: bigint; minimum?: bigint; length?: bigint; budget?: bigint; facts?: number; built?: number }
function packet(mode: number, ids: bigint[] = [], q: Query = {}): Uint8Array {
  const b = new Uint8Array(64 + ids.length * 8), w = new DataView(b.buffer);
  b.set([83, 1, mode, 0]); w.setUint32(4, ids.length, true); w.setUint32(8, 8, true); w.setUint32(12, q.facts ?? 0, true);
  [q.id ?? 64n, q.minimum ?? 64n, q.length ?? 20n, q.budget ?? 25165824n].forEach((v, i) => w.setBigUint64(16 + i * 8, v, true));
  w.setUint32(48, q.built ?? 0, true); ids.forEach((id, i) => w.setBigUint64(64 + i * 8, id, true));
  return b;
}
function result(b: Uint8Array): number[] {
  const r = derive(b); assert.deepEqual(r, dispatch(b)); assert.equal(r.length, 16);
  return Array.from({ length: 4 }, (_, i) => new DataView(r.buffer).getUint32(i * 4, true));
}
test("font registry preserves complete admission order and exact permanent identities", () => {
  const max = (1n << 64n) - 1n, rows = [64n, 65n, 66n, 67n, 68n, 69n, 70n, 71n];
  for (const id of [0n, 1n, 63n, 64n, 9007199254740992n, 9007199254740993n, max]) {
    for (const length of [0n, 25165824n, 25165825n, 1n << 32n, max]) for (const ids of [[], rows]) {
      const status = id === 0n ? 1 : id < 64n ? 2 : length > 25165824n ? 3 : ids.includes(id) ? 4 : ids.length === 8 ? 5 : 0;
      assert.equal(result(packet(0, ids, { id, length }))[1], status);
    }
  }
  const id = 9007199254740993n;
  assert.deepEqual(result(packet(0, [], { id })).slice(1), [0, 0, 3]);
  assert.deepEqual(result(packet(0, [64n], { id })).slice(1), [0, 1, 1]);
  assert.deepEqual(result(packet(1, [id - 1n, id, id], { id })).slice(1), [0, 1, 0]);
  assert.deepEqual(result(packet(1, [id], { id: id - 1n })).slice(1), [0, 4294967295, 0]);
});
test("font registry compares complete size_t words without rounded number identities", () => {
  for (const budget of [0n, 1n, 4294967295n, 4294967296n, 9007199254740992n, (1n << 64n) - 2n]) {
    assert.equal(result(packet(0, [], { budget, length: budget }))[1], 0);
    assert.equal(result(packet(0, [], { budget, length: budget + 1n }))[1], 3);
  }
});
test("font registry keeps host refusal and measurement provider precedence explicit", () => {
  for (let count = 0; count <= 8; count++) for (const facts of [0, 1]) {
    const ids = Array.from({ length: count }, (_, i) => BigInt(64 + i));
    assert.equal(result(packet(2, ids, { facts }))[1], facts ? 6 : 0);
    assert.equal(result(packet(3, ids, { facts }))[3], facts ? 1 : count ? 2 : 0);
  }
});
test("font registry repaints each live GPU slot and retries unadopted rebuild counts", () => {
  for (let facts = 0; facts < 4; facts++) assert.equal(result(packet(4, [], { facts }))[3], facts === 3 ? 1 : 0);
  for (let count = 0; count <= 8; count++) for (let built = 0; built <= 8; built++) {
    const ids = Array.from({ length: count }, (_, i) => BigInt(64 + i));
    assert.equal(result(packet(5, ids, { built }))[3], count !== built ? 1 : 0);
  }
});
test("font registry refuses incomplete packets and preserves offset typed-array views", () => {
  const valid = packet(0, [64n]);
  for (let n = 0; n < valid.length; n++) assert.throws(() => derive(valid.subarray(0, n)));
  for (const [at, value] of [[0, 82], [1, 2], [2, 6], [3, 1], [4, 9], [8, 7], [12, 4], [52, 1], [63, 1]]) {
    const b = valid.slice(); b[at!] = value!; assert.throws(() => derive(b));
  }
  const backing = new Uint8Array(valid.length + 17).fill(255); backing.set(valid, 7);
  assert.deepEqual(derive(backing.subarray(7, 7 + valid.length)), derive(valid));
});
