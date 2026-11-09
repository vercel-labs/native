import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
const words = [0n, 1n, 4294967295n, 4294967296n, 9007199254740992n, 9007199254740993n, 18446744073709551615n];
function input(mode: number, flags = 0, length = 0): Uint8Array { const b = new Uint8Array(104 + (mode === 7 ? length : mode === 9 ? 12 : 0) * 4); b.set([27, 1, mode]); new DataView(b.buffer).setUint32(4, flags, true); return b; }
function wide(b: Uint8Array, index: number, n: bigint): void { new DataView(b.buffer).setBigUint64(8 + index * 8, n, true); }
function value(b: Uint8Array, index: number): bigint { return new DataView(b.buffer).getBigUint64(8 + index * 8, true); }
function plan(b: Uint8Array): Uint8Array { const before = b.slice(), out = native_effect_policy(b); assert.equal(out.length, 104); assert.deepEqual(b, before); assert.deepEqual(out.slice(1, 8), new Uint8Array(7)); return out; }
test("snapshot bounded projections retain exact capacities and inactive admission", () => {
  for (const count of words) for (const capacity of words) for (const active of [0, 1]) {
    const b = input(0, active); wide(b, 0, count); wide(b, 1, capacity); const out = plan(b);
    assert.equal(value(out, 0), active ? count < capacity ? count : capacity : 0n);
    assert.equal(out[0], !active || !count || !capacity ? 1 : 0);
  }
});
test("snapshot view admission compares every identity bit and exact presence", () => {
  for (const id of words) for (const other of words) for (let flags = 0; flags < 4; flags++) {
    const b = input(1, flags); wide(b, 0, id); wide(b, 1, other); assert.equal(plan(b)[0], flags === 3 && id === other ? 1 : 0);
  }
  for (let flags = 0; flags < 8; flags++) assert.equal(plan(input(5, flags))[0], flags);
});
test("snapshot widget state preserves NaN roles and zero-identity focus precedence", () => {
  for (let role = 0; role <= 26; role++) for (const number of [-Infinity, -0, 0, 0.49999997, 0.5, 1, Infinity, NaN]) for (const selected of [0, 1]) {
    const b = input(2, 2 | selected); wide(b, 6, BigInt(role)); new DataView(b.buffer).setFloat32(72, number, true);
    const expected = selected || !(number < 0.5) && [12, 15, 16, 17, 18, 20].includes(role);
    assert.equal(plan(b)[0]! & 1, expected ? 1 : 0);
  }
  for (const id of words) for (const other of words) for (let flags = 0; flags < 512; flags++) {
    if (flags & 4) continue;
    const b = input(2, flags); wide(b, 0, id); for (let i = 1; i < 4; i++) wide(b, i, other);
    const out = plan(b)[0]!;
    assert.equal(out & 2, flags & 8 || flags & 16 && flags & 32 && id === other ? 2 : 0);
    assert.equal(out & 4, flags & 64 ? 0 : 4);
    assert.equal(out & 8, flags & 128 || id !== 0n && id === other ? 8 : 0);
    assert.equal(out & 16, flags & 256 || id !== 0n && id === other ? 16 : 0);
  }
});
test("snapshot parent indices, virtual saturation and uptime retain all unsigned words", () => {
  for (const a of words) for (const b of words) {
    const parent = input(2, 1024); wide(parent, 4, a); wide(parent, 5, b); const p = plan(parent);
    assert.equal(p[0]! & 32, a < b ? 32 : 0); assert.equal(value(p, 0), a < b ? a : 0n);
    for (const mode of [4, 10]) { const time = input(mode); wide(time, 0, a); wide(time, 1, b); assert.equal(value(plan(time), 0), b >= a && (mode === 10 || a > 0n) ? b - a : 0n); }
    if (a <= b) { const range = input(3, 1); [a, b, a, b].forEach((v, i) => wide(range, i, v)); const r = plan(range); assert.equal(r[0], 1); [a, b, a, b, b - a].forEach((v, i) => assert.equal(value(r, i), v > 4294967295n ? 4294967295n : v)); }
  }
  assert.deepEqual(plan(input(3)), new Uint8Array(104));
});
test("frame profile recording preserves saturation, ring wrap and exact total wrap", () => {
  const durations = [...words, 999n, 1000n, 1001n, 4294967294999n, 4294967295000n, 4294967295001n];
  for (const ns of durations) for (const count of words) for (const len of [0, 1, 127, 128]) for (const head of [0, 1, 127]) {
    const b = input(6, 1); [ns, BigInt(len), BigInt(head), count].forEach((v, i) => wide(b, i, v)); const out = plan(b);
    assert.equal(out[0], 1); assert.equal(value(out, 0), BigInt(Math.min(len + 1, 128))); assert.equal(value(out, 1), BigInt((head + 1) % 128));
    assert.equal(value(out, 2), BigInt.asUintN(64, count + 1n)); assert.equal(value(out, 3), ns / 1000n > 4294967295n ? 4294967295n : ns / 1000n);
  }
  assert.deepEqual(plan(input(8)), new Uint8Array(104));
});
test("frame profile statistics sort complete windows and use nearest rank", () => {
  for (let length = 0; length <= 128; length++) for (const total of words) for (let pattern = 0; pattern < 4; pattern++) {
    const b = input(7, 0, length), data = new DataView(b.buffer); wide(b, 0, BigInt(length)); wide(b, 1, total);
    const values = Array.from({ length }, (_, i) => pattern === 0 ? i : pattern === 1 ? 128 - i : pattern === 2 ? i % 7 : i % 2 ? 4294967295 : 0);
    values.forEach((v, i) => data.setUint32(104 + i * 4, v, true)); const out = plan(b); values.sort((a, b) => a - b);
    assert.equal(value(out, 0), BigInt(length)); assert.equal(value(out, 1), total);
    [length ? values[Math.ceil(length * .5) - 1]! : 0, length ? values[Math.ceil(length * .9) - 1]! : 0, length ? values[length - 1]! : 0].forEach((v, i) => assert.equal(value(out, 2 + i), BigInt(v)));
  }
  for (let stage = 0; stage < 12; stage++) { const b = input(9); new DataView(b.buffer).setUint32(104 + stage * 4, 1, true); assert.equal(plan(b)[0], 1); }
  assert.equal(plan(input(9))[0], 0);
});
test("snapshot transport rejects invalid headers flags ring bounds and reversed ranges", () => {
  for (const length of [0, 1, 103, 105, 615, 617]) assert.throws(() => native_effect_policy(new Uint8Array(length).fill(27)));
  for (const at of [0, 1, 2, 3]) { const b = input(0); b[at] = 255; assert.throws(() => plan(b)); }
  for (let mode = 0; mode <= 10; mode++) { const b = input(mode); new DataView(b.buffer).setUint32(4, 4096, true); assert.throws(() => plan(b)); }
  const b = input(6); wide(b, 2, 128n); assert.throws(() => plan(b));
  const range = input(3, 1); wide(range, 0, 2n); wide(range, 1, 1n); assert.throws(() => plan(range));
});
