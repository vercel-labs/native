import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";
type Rect = [number, number, number, number];
type Fact = { tag: number; bounds?: Rect; affine?: number[]; opacity?: number; fill?: number; clip?: Rect };
function request(facts: Fact[], capacity: number, batch = false): Uint8Array {
  const header = batch ? 32 : 16, r = new Uint8Array(header + facts.length * 48), w = new DataView(r.buffer);
  r[0] = 13; r[1] = batch ? 1 : 0; r[2] = 3; // IEEE zero signs: min is negative, max positive.
  w.setUint32(4, facts.length, true); w.setUint32(8, capacity, true);
  facts.forEach((v, i) => {
    const at = header + i * 48; w.setUint32(at, v.tag, true);
    if (batch) {
      w.setUint32(at + 4, v.fill ?? 0, true); w.setFloat32(at + 8, v.opacity ?? 1, true);
      w.setUint32(at + 12, v.clip ? 1 : 0, true); (v.clip ?? [0, 0, 0, 0]).forEach((f, j) => w.setFloat32(at + 16 + j * 4, f, true));
      (v.bounds ?? [0, 0, 4, 4]).forEach((f, j) => w.setFloat32(at + 32 + j * 4, f, true));
    } else {
      w.setUint32(at + 4, v.bounds && v.tag >= 5 ? 1 : 0, true);
      (v.bounds ?? [0, 0, 0, 0]).forEach((f, j) => w.setFloat32(at + 8 + j * 4, f, true));
      if (v.opacity !== undefined) w.setFloat32(at + 8, v.opacity, true);
      (v.affine ?? [0, 0, 0, 0, 0, 0]).forEach((f, j) => w.setFloat32(at + 24 + j * 4, f, true));
    }
  });
  return r;
}
function floats(w: DataView, at: number, n: number) { return Array.from({ length: n }, (_, i) => w.getFloat32(at + i * 4, true)); }
function state(r: Uint8Array) {
  const w = new DataView(r.buffer, r.byteOffset, r.byteLength), n = w.getUint32(0, true);
  return { count: n, error: w.getUint32(4, true), depths: [w.getUint32(8, true), w.getUint32(12, true)], written: [w.getUint32(16, true), w.getUint32(20, true)], opacity: w.getFloat32(24, true), transform: floats(w, 48, 6), bounds: w.getUint32(72, true) ? floats(w, 76, 4) : null,
    commands: Array.from({ length: n }, (_, i) => { const at = 864 + i * 68; return { source: w.getUint32(at, true), opacity: w.getFloat32(at + 4, true), clip: w.getUint32(at + 8, true) ? floats(w, at + 12, 4) : null, transform: floats(w, at + 28, 6), bounds: floats(w, at + 52, 4) }; }) };
}
const draw: Fact = { tag: 5, bounds: [0, 0, 12, 8] };
test("render state normalizes, composes, intersects and restores independent stacks", () => {
  const r = state(native_window_policy(request([
    { tag: 4, affine: [-2, 0, 0, 3, 30, 2] }, { tag: 0, bounds: [10, 6, -8, -4] }, { tag: 2, opacity: 0.5 }, draw, { tag: 3 }, { tag: 1 }, draw,
  ], 10)));
  assert.equal(r.error, 0); assert.deepEqual(r.depths, [0, 0]); assert.deepEqual(r.written, [1, 1]);
  assert.deepEqual(r.commands.map(v => [v.source, v.opacity, v.clip, v.bounds]), [[3, 0.5, [10, 8, 16, 12], [10, 8, 16, 12]], [6, 1, null, [6, 2, 24, 24]]]);
  assert.deepEqual(r.bounds, [6, 2, 24, 24]); assert.deepEqual(r.transform, [-2, 0, 0, 3, 30, 2]);
});
test("render capacity errors preserve preceding commands and final stack state", () => {
  const facts: Fact[] = [draw, { tag: 2, opacity: 0.5 }, draw, { tag: 3 }, { tag: 1 }];
  const full = state(native_window_policy(request(facts, 1)));
  assert.equal(full.error, 3); assert.equal(full.count, 1); assert.equal(full.opacity, 0.5); assert.deepEqual(full.depths, [0, 1]);
  const underflow = state(native_window_policy(request(facts, 9)));
  assert.equal(underflow.error, 2); assert.equal(underflow.count, 2); assert.equal(underflow.opacity, 1); assert.deepEqual(underflow.written, [0, 1]);
});
test("invisible and absent-bound draws never consume capacity or suppress stack validation", () => {
  assert.equal(state(native_window_policy(request([{ tag: 2, opacity: -1 }, draw, { tag: 3 }, { tag: 9 }], 0))).error, 0);
  assert.equal(state(native_window_policy(request([{ tag: 2, opacity: 0 }, draw, { tag: 1 }], 0))).error, 2);
  assert.equal(state(native_window_policy(request([{ tag: 0, bounds: [100, 100, 1, 1] }, draw], 0))).count, 0);
});
for (const tag of [0, 2]) test(`render stack ${tag} enforces depth 32 with complete partial state`, () => {
  const facts = Array.from({ length: 33 }, () => ({ tag, bounds: [0, 0, 20, 20] as Rect, opacity: 0.5 }));
  const r = state(native_window_policy(request(facts, 0)));
  assert.equal(r.error, 1); assert.equal(r.depths[tag === 0 ? 0 : 1], 32); assert.equal(r.written[tag === 0 ? 0 : 1], 32);
});
test("batch owner chooses every pipeline and only extends compatible adjacent commands", () => {
  const facts: Fact[] = [{ tag: 5 }, { tag: 6 }, { tag: 7, fill: 1 }, { tag: 8, fill: 1 }, { tag: 9 }, { tag: 10 }, { tag: 11 }, { tag: 12 }, { tag: 13 }, { tag: 14 }, { tag: 14, opacity: 0.5 }, { tag: 14, opacity: 0.5, clip: [0, 0, 4, 4] }];
  const r = native_window_policy(request(facts, 20, true)), w = new DataView(r.buffer, r.byteOffset, r.byteLength);
  assert.equal(w.getUint32(0, true), 9); assert.equal(w.getUint32(4, true), 0);
  assert.deepEqual(Array.from({ length: 9 }, (_, i) => [w.getUint32(32 + i * 52, true), w.getUint32(36 + i * 52, true), w.getUint32(40 + i * 52, true)]), [[0, 0, 2], [1, 2, 2], [4, 4, 2], [2, 6, 1], [3, 7, 1], [5, 8, 1], [6, 9, 1], [6, 10, 1], [6, 11, 1]]);
  const partial = native_window_policy(request(facts, 1, true)), p = new DataView(partial.buffer, partial.byteOffset, partial.byteLength);
  assert.equal(p.getUint32(4, true), 4); assert.equal(p.getUint32(40, true), 2);
});
test("batch equality keeps signed zero equal and NaN unequal", () => {
  const r = native_window_policy(request([{ tag: 5, opacity: -0 }, { tag: 5, opacity: 0 }, { tag: 5, opacity: NaN }, { tag: 5, opacity: NaN }, { tag: 5, clip: [NaN, 0, 4, 4] }, { tag: 5, clip: [NaN, 0, 4, 4] }], 6, true));
  assert.equal(new DataView(r.buffer, r.byteOffset, r.byteLength).getUint32(0, true), 5);
});
test("render results own copied bytes across subsequent operations and sliced requests", () => {
  const q = request([draw], 1), padded = new Uint8Array(q.length + 9); padded.set(q, 3);
  const r = native_window_policy(padded.subarray(3, 3 + q.length)), saved = r.slice();
  native_window_policy(request([], 0)); native_window_policy(request([{ tag: 5 }], 1, true)); assert.deepEqual(r, saved);
});
test("render wire refuses malformed counts, tags, flags and exact lengths", () => {
  const r = request([draw], 1);
  for (let n = 1; n < r.length; n++) assert.throws(() => native_window_policy(r.subarray(0, n)));
  assert.throws(() => native_window_policy(new Uint8Array([...r, 0])));
  for (const at of [1, 2, 3, 12, 16, 20]) { const bad = r.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad)); }
  const bad = r.slice(); new DataView(bad.buffer).setUint32(4, 4294967295, true); assert.throws(() => native_window_policy(bad));
});

test("render continuation retains state and commands across lazy native-bound facts", () => {
  const initial = request([draw, { tag: 2, opacity: 0.5 }, { tag: 12 }, { tag: 3 }, draw], 3), iw = new DataView(initial.buffer);
  iw.setUint32(16 + 2 * 48 + 4, 2, true);
  const pending = native_window_policy(initial), pw = new DataView(pending.buffer, pending.byteOffset, pending.byteLength);
  assert.equal(pw.getUint32(4, true), 4); assert.equal(pw.getUint32(860, true), 2); assert.equal(pw.getUint32(0, true), 1);
  const resumed = new Uint8Array(initial.length + pending.length); resumed.set(initial); resumed.set(pending, initial.length);
  const rw = new DataView(resumed.buffer); rw.setUint32(12, pending.length, true); rw.setUint32(16 + 2 * 48 + 4, 1, true);
  [1, 2, 20, 12].forEach((v, i) => rw.setFloat32(16 + 2 * 48 + 8 + i * 4, v, true));
  const result = state(native_window_policy(resumed)); assert.equal(result.error, 0); assert.deepEqual(result.commands.map(v => [v.source, v.opacity]), [[0, 1], [2, 0.5], [4, 1]]); assert.deepEqual(result.depths, [0, 0]);
  const unresolved = resumed.slice(); new DataView(unresolved.buffer).setUint32(16 + 2 * 48 + 4, 2, true); assert.throws(() => native_window_policy(unresolved));
  const bad = resumed.slice(); new DataView(bad.buffer).setUint32(initial.length + 860, 99, true); assert.throws(() => native_window_policy(bad));
});
