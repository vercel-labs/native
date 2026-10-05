import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

type Fact = { key: bigint; position?: bigint; id?: bigint | null; kind?: number; image?: bigint; font?: bigint; bucket?: number };
function request(family: number, current: Fact[], previous: Fact[], capacity = 100, actionCapacity = 100): Uint8Array {
  const r = new Uint8Array(24 + (current.length + previous.length) * 56), w = new DataView(r.buffer);
  r[0] = 12; r[1] = family;
  [current.length, previous.length, capacity, actionCapacity].forEach((n, i) => w.setUint32(4 + i * 4, n, true));
  [...current, ...previous].forEach((f, i) => {
    const at = 24 + i * 56;
    w.setUint32(at, f.kind ?? 0, true); w.setUint32(at + 4, f.id == null ? 0 : 1, true);
    w.setBigUint64(at + 8, f.id ?? 0n, true); w.setBigUint64(at + 16, f.position ?? 0n, true);
    w.setBigUint64(at + 24, f.image ?? 0n, true); w.setBigUint64(at + 32, f.font ?? 0n, true);
    w.setBigUint64(at + 40, f.key, true); w.setUint32(at + 48, f.bucket ?? Number(f.key & 4095n), true);
  });
  return r;
}
function decode(r: Uint8Array) {
  const w = new DataView(r.buffer), n = w.getUint32(0, true), m = w.getUint32(4, true);
  return { failed: w.getUint32(8, true), entries: Array.from({ length: n }, (_, i) => w.getUint32(16 + i * 4, true)), actions: Array.from({ length: m }, (_, i) => Array.from({ length: 3 }, (_, j) => w.getUint32(16 + n * 4 + i * 12 + j * 4, true))) };
}
for (let family = 0; family < 6; family++) {
  test(`render cache ${family} preserves ordering, first matches and every unused previous duplicate`, () => {
    assert.deepEqual(decode(native_window_policy(request(family, [{ key: 2n }, { key: 2n }, { key: 3n }], [{ key: 2n }, { key: 2n }, { key: 4n }, { key: 4n }]))), { failed: 0, entries: [0, 2], actions: [[1, 0, 0], [0, 2, 4294967295], [2, 5, 2], [2, 6, 3]] });
  });
  test(`render cache ${family} writes actions before entries on capacity failures`, () => {
    const c = [{ key: 1n }, { key: 2n }];
    assert.deepEqual(decode(native_window_policy(request(family, c, [], 0, 9))), { failed: 1, entries: [], actions: [[0, 0, 4294967295]] });
    assert.deepEqual(decode(native_window_policy(request(family, c, [], 1, 9))), { failed: 1, entries: [0], actions: [[0, 0, 4294967295], [0, 1, 4294967295]] });
    assert.deepEqual(decode(native_window_policy(request(family, c, [], 9, 1))), { failed: 1, entries: [0], actions: [[0, 0, 4294967295]] });
    assert.deepEqual(decode(native_window_policy(request(family, [], c, 0, 1))), { failed: 1, entries: [], actions: [[2, 0, 0]] });
  });
  test(`render cache ${family} compares every complete key field without uint64 rounding`, () => {
    const base: Fact = { key: 9007199254740993n, id: 0n, position: 9007199254740993n, image: 18446744073709551615n, font: 9007199254740997n };
    const facts = [base, { ...base, key: base.key + 1n }, { ...base, id: null }, { ...base, id: 1n }, { ...base, position: base.position! + 1n }, { ...base, image: base.image! - 1n }, { ...base, font: base.font! + 1n }, { ...base, kind: 1 }];
    const out = decode(native_window_policy(request(family, facts, [base])));
    assert.deepEqual(out.entries, facts.map((_, i) => i)); assert.equal(out.actions[0]![0], 1); assert.ok(out.actions.slice(1).every(a => a[0] === 0));
  });
}
test("generic render resources preserve indexed collisions, threshold and oversized linear parity", () => {
  for (const count of [63, 64, 2048, 2049]) {
    const c = Array.from({ length: count }, (_, i) => ({ key: BigInt(i >> 1), bucket: 17 }));
    const out = decode(native_window_policy(request(4, c, c, count, count * 2)));
    assert.equal(out.entries.length, Math.ceil(count / 2)); assert.deepEqual(out.actions.map(a => a[2]), out.entries);
  }
  const previous = Array.from({ length: 64 }, (_, i) => ({ key: BigInt(i >> 1), bucket: 1 }));
  assert.deepEqual(decode(native_window_policy(request(4, [], previous, 0, 64))).actions.map(a => a[2]), previous.map((_, i) => i));
});
test("render cache copied results survive later family calls and sliced wire views", () => {
  const r = request(4, [{ key: 1n }], []), padded = new Uint8Array(r.length + 9); padded.set(r, 4);
  const output = native_window_policy(padded.subarray(4, 4 + r.length)), before = output.slice();
  for (let family = 0; family < 6; family++) native_window_policy(request(family, [], []));
  assert.deepEqual(output, before); assert.equal(decode(output).entries.length, 1);
});
test("render cache wire refuses malformed shape, reserved fields and discriminators", () => {
  const r = request(4, [{ key: 1n }], []);
  for (let i = 1; i < r.length; i++) assert.throws(() => native_window_policy(r.subarray(0, i)));
  assert.throws(() => native_window_policy(new Uint8Array([...r, 0])));
  for (const at of [1, 2, 3, 20, 24 + 52]) { const bad = r.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad)); }
  const bad = r.slice(); new DataView(bad.buffer).setUint32(4, 4294967295, true); assert.throws(() => native_window_policy(bad));
});
