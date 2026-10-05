import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";
type Override = { id: bigint; opacity?: number; transform?: number[] };
const identity = [1, 0, 0, 1, 0, 0];
function request(first: Override[], second: Override[], capacity: number): Uint8Array {
  const b = new Uint8Array(32 + (first.length + second.length) * 40), w = new DataView(b.buffer);
  b[0] = 14; b[2] = 3; w.setUint32(4, first.length, true); w.setUint32(8, second.length, true); w.setUint32(20, capacity, true);
  [...first, ...second].forEach((v, i) => {
    const at = 32 + i * 40; w.setBigUint64(at, v.id, true); w.setUint32(at + 8, (v.opacity !== undefined ? 1 : 0) | (v.transform ? 2 : 0), true);
    w.setFloat32(at + 12, v.opacity ?? 0, true); (v.transform ?? identity).forEach((x, j) => w.setFloat32(at + 16 + j * 4, x, true));
  });
  return b;
}
function merge(a: Override[], b: Override[], capacity: number) {
  const r = native_window_policy(request(a, b, capacity)), w = new DataView(r.buffer, r.byteOffset, r.byteLength);
  return { failed: w.getUint32(4, true), sources: Array.from({ length: w.getUint32(0, true) }, (_, i) => w.getUint32(16 + i * 4, true)) };
}
const id = 9007199254740993n;
test("override merging retains scheduled duplicates and replaces the first exact matching ID", () => {
  assert.deepEqual(merge([{ id }, { id }, { id: id + 1n }], [{ id }, { id: id + 2n }, { id }], 4), { failed: 0, sources: [5, 1, 2, 4] });
});
test("override merge capacity failure preserves every accepted and replaced prefix", () => {
  assert.deepEqual(merge([{ id }, { id: id + 1n }], [{ id }, { id: id + 2n }, { id: id + 1n }], 2), { failed: 1, sources: [2, 1] });
  assert.deepEqual(merge([{ id }, { id }], [{ id }], 1), { failed: 1, sources: [0] });
  assert.deepEqual(merge([], [{ id }, { id }], 0), { failed: 1, sources: [] });
});
test("override merge owns copied results across sliced inputs and subsequent calls", () => {
  const r = request([{ id }], [{ id }], 1), padded = new Uint8Array(r.length + 8); padded.set(r, 3);
  const result = native_window_policy(padded.subarray(3, 3 + r.length)), before = result.slice();
  native_window_policy(request([], [], 0)); assert.deepEqual(result, before);
});
function apply(previous: Override[], next: Override[], opacity = 1, rect = [0, 0, 10, 8], hasId = true, entries: { id: bigint; bounds?: number[] }[] = []) {
  const head = request(previous, next, 0), commandAt = head.length, entryAt = commandAt + 92;
  const r = new Uint8Array(entryAt + entries.length * 28); r.set(head); r[1] = 1; const w = new DataView(r.buffer);
  w.setUint32(12, 1, true); w.setUint32(16, entries.length, true);
  w.setBigUint64(commandAt, id, true); w.setUint32(commandAt + 8, hasId ? 1 : 0, true); w.setFloat32(commandAt + 12, opacity, true);
  identity.forEach((x, i) => w.setFloat32(commandAt + 16 + i * 4, x, true));
  for (const at of [40, 56]) rect.forEach((x, i) => w.setFloat32(commandAt + at + i * 4, x, true));
  entries.forEach((entry, i) => { const at = entryAt + i * 28; w.setBigUint64(at, entry.id, true); w.setUint32(at + 8, entry.bounds ? 1 : 0, true); entry.bounds?.forEach((x, j) => w.setFloat32(at + 12 + j * 4, x, true)); });
  const bytes = native_window_policy(r), out = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const bounds = (at: number) => out.getUint32(at, true) ? Array.from({ length: 4 }, (_, i) => out.getFloat32(at + 4 + i * 4, true)) : null;
  return { bytes, bounds: bounds(4), dirty: bounds(24), animationDirty: bounds(44), opacity: out.getFloat32(64, true), transform: Array.from({ length: 6 }, (_, i) => out.getFloat32(68 + i * 4, true)) };
}
test("override application composes transforms but damage includes both old and new clipped geometry", () => {
  const r = apply([{ id, transform: [1, 0, 0, 1, -20, 0] }], [{ id, opacity: 0.5, transform: [2, 0, 0, 2, 5, 3] }]);
  assert.deepEqual(r.bounds, [5, 3, 20, 16]); assert.deepEqual(r.dirty, [-20, 0, 45, 19]); assert.equal(r.opacity, 0.5);
});
test("missing IDs keep command state and opacity-only overrides still produce conservative damage", () => {
  assert.equal(apply([], [{ id, opacity: 0 }], 1, [0, 0, 10, 8], false).opacity, 1);
  assert.deepEqual(apply([], [{ id, opacity: 0 }]).dirty, [0, 0, 10, 8]);
  assert.equal(apply([{ id, opacity: -0 }], [{ id, opacity: 0 }]).dirty, null);
  assert.deepEqual(apply([{ id, opacity: NaN }], [{ id, opacity: NaN }]).dirty, [0, 0, 10, 8]);
});
test("animation damage selects exact IDs and normalizes every admitted rectangle", () => {
  const r = apply([], [{ id }], 1, [0, 0, 10, 8], true, [{ id: id + 1n, bounds: [-999, -999, 9999, 9999] }, { id, bounds: [10, 10, -4, -8] }, { id }]);
  assert.deepEqual(r.animationDirty, [6, 2, 4, 8]);
});
test("override wire rejects malformed counts masks modes reserved fields and lengths", () => {
  const r = request([{ id }], [], 1);
  for (let i = 1; i < r.length; i++) assert.throws(() => native_window_policy(r.subarray(0, i)));
  assert.throws(() => native_window_policy(new Uint8Array([...r, 0])));
  for (const at of [1, 2, 3, 12, 16, 24, 28, 40]) { const bad = r.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad)); }
});
