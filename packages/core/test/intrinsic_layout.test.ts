import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

type Child = { flags?: number; measured?: number[]; authored?: number[]; min?: number[]; max?: number[]; wrapped?: number };
function request(op: number, children: Child[] = [], values: number[] = [], axis = 0, flags = 0, columns = 0n): Uint8Array {
  const bytes = new Uint8Array(96 + children.length * 40), d = new DataView(bytes.buffer);
  bytes.set([6, op, axis, flags]); d.setUint32(4, children.length, true); d.setBigUint64(8, columns, true);
  d.setFloat32(16, Number(columns), true); d.setFloat32(20, Number(columns > 0n ? columns - 1n : 0n), true);
  values.forEach((v, i) => d.setFloat32(24 + i * 4, v, true));
  children.forEach((c, i) => { const at = 96 + i * 40; d.setUint32(at, c.flags ?? 1, true);
    [...(c.measured ?? [0, 0]), ...(c.authored ?? [0, 0]), ...(c.min ?? [0, 0]), ...(c.max ?? [0, 0]), c.wrapped ?? 0].forEach((v, n) => d.setFloat32(at + 4 + n * 4, v, true)); });
  return bytes;
}
function size(q: Uint8Array, at = 4): number[] { const b = native_window_policy(q), d = new DataView(b.buffer); return [d.getFloat32(at, true), d.getFloat32(at + 4, true)]; }
test("intrinsic child bounds apply authored floors before maximum and minimum constraints", () => {
  assert.deepEqual(size(request(0, [{ measured: [80, 20], authored: [40, 60], min: [90, 0], max: [50, 40] }]), 12), [90, 40]);
  assert.deepEqual(size(request(0, [{ flags: 0, measured: [900, 900] }]), 12), [0, 0]);
});
test("flow composition preserves axis ordering separators gaps and parent padding", () => {
  const children = [{ measured: [40, 20] }, { flags: 3, measured: [160, 2] }, { flags: 0, measured: [999, 999] }, { measured: [60, 30] }];
  assert.deepEqual(size(request(1, children, [0, 0, 3, 4, 5, 6, 8])), [125, 41]);
  assert.deepEqual(size(request(1, children, [0, 0, 3, 4, 5, 6, 8], 1)), [167, 79]);
  children[1] = { flags: 3, measured: [160, 2], authored: [100, 0] } as typeof children[1];
  assert.deepEqual(size(request(1, children)), [260, 30]);
});
test("empty stopped and all-hoisted containers retain distinct intrinsic contracts", () => {
  const values = [2, 3, 10, 11, 12, 13];
  for (const op of [1, 2, 4]) assert.deepEqual(size(request(op, [], values)), [2, 3]);
  assert.deepEqual(size(request(2, [{ flags: 0 }], values)), [21, 25]);
  assert.deepEqual(size(request(1, [{ flags: 0 }], values)), [2, 3]);
  assert.deepEqual(size(request(3, [], values)), [0, 3]);
  assert.deepEqual(size(request(5, [], values, 0, 1)), [0, 0]);
});
test("grid composition retains declared columns beyond safe integers and safe row division", () => {
  const children = [{ measured: [2, 3] }, { measured: [4, 5] }, { measured: [1, 1] }];
  assert.deepEqual(size(request(4, children, [0, 0, 0, 0, 0, 0, 2], 0, 0, 2n)), [10, 12]);
  assert.deepEqual(size(request(4, children)), [12, 5]);
  for (const columns of [9007199254740993n, 18446744073709551615n]) {
    const q = request(4, children, [], 0, 0, columns), d = new DataView(q.buffer); d.setFloat32(16, Number(columns), true);
    assert.deepEqual(size(q), [Math.fround(4 * Math.fround(Number(columns))), 5]);
  }
});
test("horizontal scrolling uses native wrapped heights and compiled natural measurement widths", () => {
  const q = request(3, [{ measured: [80, 20], authored: [40, 0], wrapped: 60 }, { measured: [90, 50], wrapped: 30 }], [100, 0, 3, 4, 5, 6]);
  assert.deepEqual(size(q), [0, 71]);
  const out = native_window_policy(q), d = new DataView(out.buffer); assert.equal(d.getFloat32(20, true), 40); assert.equal(d.getFloat32(32, true), 90);
});
test("decorated surfaces distinguish card floors modal content hugs and disclosed headers", () => {
  const child = [{ measured: [200, 50] }], values = [0, 0, 10, 20, 30, 40, 8, 0, 0, 40, 24, 240, 120, 16];
  assert.deepEqual(size(request(8, child, values, 0, 2)), [240, 120]);
  assert.deepEqual(size(request(9, child, values, 0, 2)), [240, 120]);
  values[5] = 0; values[4] = 0;
  assert.deepEqual(size(request(9, child, values)), [240, 50]);
  assert.deepEqual(size(request(9, child, values, 0, 2)), [240, 56]);
  assert.deepEqual(size(request(7, child, values)), [230, 82]);
  assert.deepEqual(size(request(7, [], values)), [30, 24]);
});
test("alerts retain title icon description gaps and untitled content sizing", () => {
  const values = [0, 0, 10, 20, 30, 40, 0, 0, 0, 300, 24, 240, 52, 0, 16, 8, 4];
  assert.deepEqual(size(request(10, [{ measured: [500, 100] }], values, 0, 2)), [554, 198]);
  assert.deepEqual(size(request(10, [{ measured: [500, 100] }], values)), [530, 170]);
});
test("intrinsic records reject every truncation surplus invalid enum reserved lane and child flag", () => {
  for (const op of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) {
    const q = request(op, [{}]);
    for (let n = 1; n < q.length; n++) assert.throws(() => native_window_policy(q.subarray(0, n)), /intrinsic/);
    assert.throws(() => native_window_policy(new Uint8Array([...q, 0])), /intrinsic/);
    for (const at of [1, 2, 3, 4, 92, 96]) { const bad = q.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad), /intrinsic/); }
  }
});
test("large intrinsic results own bytes across subviews recursion input changes and later calls", () => {
  const q = request(1, Array.from({ length: 128 }, (_, i) => ({ measured: [i + 1, i + 2] }))), padded = new Uint8Array(q.length + 17); padded.set(q, 9);
  const result = native_window_policy(padded.subarray(9, 9 + q.length)), saved = result.slice();
  assert.deepEqual(result, native_window_policy(q)); padded.fill(0); native_window_policy(request(9)); assert.deepEqual(result, saved);
});
test("shared padding applies parent floors with native f32 addition order", () => {
  assert.deepEqual(size(request(6, [], [100, 80, 3, 5, 7, 11, 0, 40, 60])), [100, 80]);
  assert.deepEqual(size(request(6, [], [0, 0, -3, 5, 7, -11, 0, 40, 60])), [42, 56]);
});
test("intrinsic numeric boundaries retain NaN extrema and declared constraints", () => {
  assert.deepEqual(size(request(0, [{ measured: [NaN, Infinity], authored: [-Infinity, 0], min: [3, 4], max: [10, 40] }]), 12), [3, 40]);
  assert.deepEqual(size(request(1, [{ measured: [3, 4] }, { measured: [5, 6] }], [0, 0, 0, 0, 0, 0, NaN])), [8, 6]);
});
