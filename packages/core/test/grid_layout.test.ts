import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

function plan(count = 7, columns = 3, virtual = false, scroll = 0, overscan = 0): Uint8Array {
  const bytes = new Uint8Array(76), data = new DataView(bytes.buffer);
  bytes.set([4, 0, virtual ? 5 : 4, 0]);
  for (const [at, value] of [[4, count], [12, columns], [20, overscan]]) {
    data.setUint32(at!, value! % 4294967296, true); data.setUint32(at! + 4, Math.floor(value! / 4294967296), true);
  }
  const floats = [0, 0, 600, 160, 8, 40, 0, scroll, Math.fround(count), Math.fround(columns), Math.fround(Math.max(0, count - 1)), Math.fround(Math.max(0, columns - 1))];
  floats.forEach((value, i) => data.setFloat32(28 + i * 4, value, true)); return bytes;
}
function decode(bytes: Uint8Array): number[] {
  assert.equal(bytes.length, 52); const d = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return [0, 8, 16, 24].map(at => d.getUint32(at, true) + d.getUint32(at + 4, true) * 4294967296).concat([32, 36, 40, 44, 48].map(at => d.getFloat32(at, true)));
}
function cell(): Uint8Array {
  const b = new Uint8Array(76), d = new DataView(b.buffer); b.set([4, 1, 0, 0]); d.setUint32(4, 4, true); d.setUint32(12, 3, true);
  [10, 20, 100, 40, 8, 0, 2, 3, 0, 0, 0, 0, 0, 0].forEach((v, i) => d.setFloat32(20 + i * 4, v, true)); return b;
}
function frame(b: Uint8Array): number[] { assert.equal(b.length, 17); assert.equal(b[0], 1); const d = new DataView(b.buffer, b.byteOffset, b.byteLength); return [1, 5, 9, 13].map(at => d.getFloat32(at, true)); }

test("grid plans preserve declared trailing slots, empty grids, and default columns", () => {
  assert.deepEqual(decode(native_window_policy(plan())), [3, 3, 0, 7, Math.fround(584 / 3), 48, 8, 0, 0]);
  assert.equal(decode(native_window_policy(plan(2, 5)))[0], 5);
  assert.equal(decode(native_window_policy(plan(2, 0)))[0], 2);
  assert.deepEqual(decode(native_window_policy(plan(0, 5))).slice(0, 4), [0, 0, 0, 0]);
  const large = plan(2, 1); const d = new DataView(large.buffer); d.setUint32(12, 0xffffffff, true); d.setUint32(16, 0xffffffff, true); d.setFloat32(64, 2 ** 64, true); d.setFloat32(72, 2 ** 64, true);
  assert.deepEqual([...native_window_policy(large).subarray(0, 8)], Array(8).fill(255));
});
test("virtual grid plans clamp row visibility and retain elastic displacement", () => {
  assert.deepEqual(decode(native_window_policy(plan(30, 3, true, 50, 1))).slice(0, 4), [3, 10, 0, 6]);
  assert.equal(decode(native_window_policy(plan(30, 3, true, -500)))[7], -160);
  assert.equal(decode(native_window_policy(plan(30, 3, true, Infinity)))[7], 0);
  const empty = plan(30, 3, true); new DataView(empty.buffer).setFloat32(40, 0, true);
  assert.deepEqual(decode(native_window_policy(empty)).slice(2, 4), [0, 0]);
});
test("grid cells preserve offsets, constraints, implicit fill, and virtual scrolling", () => {
  assert.deepEqual(frame(native_window_policy(cell())), [120, 71, 100, 40]);
  const b = cell(), d = new DataView(b.buffer); b[2] = 3; d.setFloat32(40, 24, true); d.setFloat32(52, 64, true);
  assert.deepEqual(frame(native_window_policy(b)), [120, 47, 98, 40]);
  d.setFloat32(68, 80, true); assert.equal(frame(native_window_policy(b))[2], 80);
});
test("grid wire rejects every truncation, extra bytes, reserved flags and unsafe indices", () => {
  for (const valid of [plan(), cell()]) {
    for (let n = 1; n < valid.length; n++) assert.throws(() => native_window_policy(valid.subarray(0, n)), /grid/);
    assert.throws(() => native_window_policy(new Uint8Array([...valid, 0])), /grid/);
    for (const at of [1, 2, 3]) { const invalid = valid.slice(); invalid[at] = 255; assert.throws(() => native_window_policy(invalid), /grid/); }
  }
  const unsafe = plan(); new DataView(unsafe.buffer).setUint32(8, 0x200000, true); assert.throws(() => native_window_policy(unsafe), /child count/);
  const overflow = plan(30, 3, true); const d = new DataView(overflow.buffer); d.setUint32(20, 0xffffffff, true); d.setUint32(24, 0xffffffff, true);
  assert.throws(() => native_window_policy(overflow), /overflow/); overflow[2] = 1;
  assert.equal(decode(native_window_policy(overflow))[3], 3);
});
test("grid bytes honor offset views and copied output ownership", () => {
  for (const valid of [plan(), cell()]) {
    const padded = new Uint8Array(valid.length + 13).fill(255); padded.set(valid, 7);
    const owned = native_window_policy(padded.subarray(7, 7 + valid.length)), copy = owned.slice();
    assert.deepEqual(owned, native_window_policy(valid)); padded.fill(0); native_window_policy(plan(0)); assert.deepEqual(owned, copy);
  }
});
