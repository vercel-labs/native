import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/text_measurement_cache.ts", import.meta.url), "utf8");
const { nscvTextMeasurementCache: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvTextMeasurementCache};").toString("base64")}`);
function packet(mode: number, length = 1, flags = 0): Uint8Array {
  const count = mode === 1 || mode === 2 ? length > 2048 ? 257 : 256 : mode === 4 || mode === 5 ? 256 : 0;
  const bytes = new Uint8Array(count === 0 ? mode === 6 ? 32 + length * 4 : 32 : 128 + count * 104), w = new DataView(bytes.buffer);
  bytes.set([58, 1, mode, flags]); w.setUint32(4, count, true); w.setUint32(8, length, true);
  if (count > 0) { w.setUint32(120, 1, true); w.setUint32(32, 7, true); }
  return bytes;
}
function run(bytes: Uint8Array): number[] {
  const before = bytes.slice(), result = plan(bytes);
  assert.deepEqual(bytes, before); assert.equal(result.length, 16);
  const w = new DataView(result.buffer); return [0, 4, 8, 12].map(at => w.getUint32(at, true));
}
function fact(bytes: Uint8Array, slot: number, tick: bigint, same = false): void {
  const w = new DataView(bytes.buffer), at = 128 + slot * 104;
  bytes.set(bytes.subarray(32, 120), at);
  if (!same) w.setUint32(at, slot + 100, true);
  w.setUint32(at + 88, 1, true); w.setBigUint64(at + 96, tick, true);
}
test("measured text admission preserves absent providers empty runs and peek allocation", () => {
  for (const length of [0, 2048, 2049, 65536, 65537]) for (let flags = 0; flags < 8; flags++) {
    const expected = !(flags & 1) ? 0 : length === 0 ? 1 : length > 65536 || !(flags & 4) && !(flags & 2) ? 0 : 6;
    assert.deepEqual(run(packet(0, length, flags)), [expected, 0xffffffff, 0, 0]);
  }
  for (const capacity of [0, 159, 160, 161]) for (const measured of [0, 1]) {
    const p = packet(3, 0, measured); new DataView(p.buffer).setUint32(12, capacity, true);
    assert.equal(run(p)[0], measured && capacity >= 160 ? 6 : 0);
  }
});
test("measured cache keys and LRU preserve every u64 word above Number precision", () => {
  const p = packet(1), w = new DataView(p.buffer);
  for (let i = 0; i < 256; i++) fact(p, i, 0xffffffffffffffffn);
  fact(p, 1, 0x0020000000000002n); fact(p, 2, 0x0020000000000001n);
  assert.deepEqual(run(p), [3, 2, 5, 0]);
  fact(p, 33, 1n, true); fact(p, 47, 0n, true);
  assert.deepEqual(run(p), [2, 33, 3, 0]);
  // High words of hashes, pointers and generations independently mismatch.
  for (const offset of [4, 12, 28, 36, 44, 52, 60, 68, 76]) {
    const q = p.slice(), view = new DataView(q.buffer); view.setUint32(128 + 33 * 104 + offset, 0xffffffff, true); view.setUint32(128 + 47 * 104 + offset, 0x80000000, true);
    assert.equal(run(q)[0], 3);
  }
  w.setUint32(128 + 33 * 104 + 88, 0, true); w.setUint32(128 + 47 * 104 + 88, 0, true);
  assert.deepEqual(run(p), [3, 33, 5, 0]);
});
test("oversize peek memoization never touches LRU while small peeks do", () => {
  for (const mode of [1, 2]) for (const length of [2048, 2049, 65536]) {
    const p = packet(mode, length), slot = length > 2048 ? 256 : 3;
    fact(p, slot, 0xffffffffffffffffn, true);
    assert.deepEqual(run(p), [2, slot, mode === 2 && length > 2048 ? 2 : 3, 0]);
  }
  assert.deepEqual(run(packet(2, 2049)), [0, 0xffffffff, 0, 0]);
  assert.deepEqual(run(packet(1, 2049)), [3, 256, 5, 0]);
});
test("batch acceptance rejects negative nonfinite advances and preserves signed zero", () => {
  for (const value of [0, -0, 1, Number.MAX_VALUE, -1, NaN, Infinity, -Infinity]) {
    const p = packet(6, 3, 1); new DataView(p.buffer).setFloat32(36, value, true);
    assert.equal(run(p)[0], value >= 0 && Number.isFinite(Math.fround(value)) ? 5 : 0);
  }
});
test("paragraph misses stores and malformed range admission preserve all-or-nothing rebasing", () => {
  assert.deepEqual(run(packet(4)), [0, 0xffffffff, 8, 0]);
  assert.deepEqual(run(packet(5, 160, 1)), [4, 0, 1, 0]);
  assert.deepEqual(run(packet(5, 161, 1)), [0, 0xffffffff, 0, 0]);
  assert.deepEqual(run(packet(5, 160, 0)), [0, 0xffffffff, 0, 0]);
  const p = new Uint8Array(32 + 2 * 4 + 2 * 12), w = new DataView(p.buffer);
  p.set([58, 1, 7, 0]); w.setUint32(4, 2, true); w.setUint32(8, 2, true); w.setUint32(32, 3, true); w.setUint32(36, 5, true);
  w.setUint32(44, 1, true); w.setUint32(48, 2, true); w.setUint32(52, 1, true); w.setUint32(56, 2, true); w.setUint32(60, 3, true);
  assert.equal(run(p)[0], 5); w.setUint32(60, 4, true); assert.equal(run(p)[0], 0);
  w.setUint32(52, 2, true); assert.equal(run(p)[0], 0);
});
test("measured cache rejects truncated padded and foreign packets before any state mutation", () => {
  const p = packet(1);
  for (const length of [0, 31, 32, 119, p.length - 1]) assert.throws(() => plan(p.subarray(0, length)));
  for (const offset of [0, 1, 2, 3, 16, 20, 24, 28, 124, 128 + 92]) { const q = p.slice(); q[offset] = 255; assert.throws(() => plan(q)); }
});
