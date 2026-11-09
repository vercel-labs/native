import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "image_registry.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvImageRegistry: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvImageRegistry};").toString("base64")}`);
interface Record { id?: bigint; fingerprint?: bigint; flags?: number }
interface Query { id?: bigint; width?: bigint; height?: bigint; length?: bigint; budget?: bigint; fingerprint?: bigint; cursor?: number; facts?: number; bits?: number; capacity?: number }
function packet(mode: number, entries: Record[] = [], q: Query = {}): Uint8Array {
  const b = new Uint8Array(96 + entries.length * 32), w = new DataView(b.buffer);
  b.set([82, 1, mode, q.bits ?? 64]); w.setUint32(4, entries.length, true); w.setUint32(8, q.capacity ?? (mode <= 3 ? 16 : mode === 4 ? 32 : 4), true);
  w.setUint32(12, q.cursor ?? 0, true); w.setUint32(16, q.facts ?? 0, true); w.setUint32(20, 8388608, true);
  [q.id ?? 1n, q.width ?? 1n, q.height ?? 1n, q.length ?? 4n, q.budget ?? 1048576n, q.fingerprint ?? 0n].forEach((v, i) => w.setBigUint64(24 + i * 8, v, true));
  entries.forEach((r, i) => { const at = 96 + i * 32; w.setBigUint64(at, r.id ?? 1n, true); w.setBigUint64(at + 8, r.fingerprint ?? 0n, true); w.setUint32(at + 16, r.flags ?? 0, true); });
  return b;
}
function result(b: Uint8Array): number[] {
  const a = derive(b); assert.deepEqual(a, dispatch(b)); assert.equal(a.length, 32);
  return Array.from({ length: 8 }, (_, i) => new DataView(a.buffer).getUint32(i * 4, true));
}
test("image registry preserves native size_t overflow and validation precedence", () => {
  const max = (1n << 64n) - 1n;
  const dimensions = [0n, 1n, 2n, 65535n, 65536n, 1048576n, 4294967295n, 4294967296n, 1n << 62n, max];
  for (const bits of [32, 64]) for (const width of dimensions) for (const height of dimensions) {
    const product = width * height * 4n, overflow = product >= (1n << BigInt(bits));
    for (const length of [0n, product & max, (product + 1n) & max]) {
      const expected = width === 0n || height === 0n || overflow || length !== product ? 2 : product > 1048576n ? 3 : 0;
      assert.equal(result(packet(0, [], { bits, width, height, length }))[2], expected);
    }
  }
  assert.equal(result(packet(0, [], { id: 0n, width: 0n }))[2], 1);
  assert.equal(result(packet(0, [], { id: 1n << 63n, width: 0n }))[2], 1);
});
test("image registry retains exact identities, first matches, replacement and full admission", () => {
  const id = 9007199254740993n;
  const rows = Array.from({ length: 16 }, (_, i) => ({ id: BigInt(i + 1) }));
  assert.equal(result(packet(0, rows, { id }))[2], 4);
  assert.deepEqual(result(packet(0, rows, { id: 2n })).slice(2, 5), [0, 1, 1]);
  assert.deepEqual(result(packet(0, [{ id }, { id }], { id })).slice(2, 5), [0, 0, 1]);
  assert.equal(result(packet(0, [], { id: (1n << 63n) - 1n }))[2], 0);
  assert.equal(result(packet(2, [{ id: id - 1n }, { id }], { id }))[3], 1);
  assert.deepEqual(result(packet(3, rows, { id })).slice(3, 5), [4294967295, 0]);
  assert.deepEqual(result(packet(3, rows, { id: 2n })).slice(3, 5), [1, 2]);
});
test("image registry checks encoded source bounds before codec capabilities", () => {
  for (const length of [0n, 8388608n, 8388609n, 1n << 32n]) {
    const r = result(packet(1, [], { length })); assert.equal(r[2], length > 8388608n ? 3 : 0); assert.equal(r[4], length > 8388608n ? 0 : 1);
  }
  assert.equal(result(packet(1, [], { id: 0n, length: 1n << 32n }))[2], 1);
});
test("image registry repaint derives each current view without conflating open and GPU flags", () => {
  for (let flags = 0; flags < 4; flags++) assert.equal(result(packet(4, [{ flags }]))[4], flags === 3 ? 4 : 0);
});
test("image registry media reclamation requests one ordered ownership observation at a time", () => {
  const rows = [1n, 2n, 3n, 4n].map(id => ({ id }));
  assert.deepEqual(result(packet(5, rows, { id: 5n })).slice(3, 6), [4294967295, 16, 0]);
  for (let cursor = 0; cursor < 4; cursor++) {
    assert.deepEqual(result(packet(5, rows, { id: 5n, cursor, facts: 1 })).slice(3, 6), [cursor, 32, 4294967295]);
    assert.deepEqual(result(packet(5, rows, { id: 5n, cursor, facts: 3 })).slice(4, 6), cursor < 3 ? [16, cursor + 1] : [0, 4294967295]);
  }
  assert.deepEqual(result(packet(5, rows.slice(0, 3), { id: 5n })).slice(3, 5), [3, 8]);
  assert.deepEqual(result(packet(5, rows, { id: 3n })).slice(3, 5), [2, 1]);
});
test("image registry media deduplication and purge preserve complete fingerprint words", () => {
  const value = (1n << 64n) - 1n;
  assert.equal(result(packet(6, [], { budget: value, fingerprint: value }))[4], 64);
  assert.equal(result(packet(6, [], { budget: value - 1n, fingerprint: value }))[4], 0);
  for (const mode of [7, 8]) {
    const rows = [{ id: 7n }, { id: 7n, fingerprint: value }, { id: 7n, fingerprint: 1n }];
    const r = result(packet(mode, rows, { id: 7n })); assert.equal(r[3], 1); assert.equal(r[4], mode === 8 ? 128 : 0);
  }
});
test("image registry refuses malformed transport before accessing observations", () => {
  const valid = packet(0, [{}]);
  for (let n = 0; n < valid.length; n++) assert.throws(() => derive(valid.subarray(0, n)));
  for (const [at, value] of [[0, 81], [1, 2], [2, 9], [3, 16], [4, 17], [8, 33], [16, 4], [72, 1], [95, 1], [112, 4], [116, 1], [127, 1]]) {
    const b = valid.slice(); b[at!] = value!; assert.throws(() => derive(b));
  }
});
