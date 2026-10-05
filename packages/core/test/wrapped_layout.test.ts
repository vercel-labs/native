import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

type Child = { flags?: number; authored?: number; resolved?: number; height?: number };
function request(kind: number, children: Child[] = [], values: number[] = [], flags = 0, op = 1, depth = 0): Uint8Array {
  const bytes = new Uint8Array(80 + children.length * 16), d = new DataView(bytes.buffer);
  bytes.set([7, op, kind, flags]); d.setUint32(4, children.length, true); d.setUint32(8, depth, true); d.setUint32(12, 32, true);
  [240, 0, 0, 0, 0, 0, 0, 0, 0, 24, 24, 52, 0, 0, 12, 4].forEach((v, i) => d.setFloat32(16 + i * 4, values[i] ?? v, true));
  children.forEach((c, i) => { const at = 80 + i * 16; d.setUint32(at, c.flags ?? 1, true); d.setFloat32(at + 4, c.authored ?? 0, true); d.setFloat32(at + 8, c.resolved ?? 0, true); d.setFloat32(at + 12, c.height ?? 0, true); });
  return bytes;
}
function plan(q: Uint8Array) {
  const b = native_window_policy(q), d = new DataView(b.buffer), count = d.getUint32(0, true);
  return { action: d.getUint32(4, true), inner: d.getFloat32(8, true), height: d.getFloat32(12, true), mode: d.getUint32(16, true), widths: Array.from({ length: count }, (_, i) => d.getFloat32(20 + i * 8, true)), queries: Array.from({ length: count }, (_, i) => d.getUint32(24 + i * 8, true)) };
}
test("wrapped sizing selects the full stable kind table without changing classic leaf contracts", () => {
  const columns = [2, 4, 5, 7, 24, 25], overlays = [0, 15, 16, 18, 22, 23], rows = [1, 8, 9, 10, 11, 12, 13, 43];
  for (let kind = 0; kind <= 62; kind++) {
    const p = plan(request(kind, [], [], 8));
    const mode = columns.includes(kind) ? 2 : overlays.includes(kind) ? 3 : rows.includes(kind) ? 6 : kind === 17 ? 4 : kind === 14 ? 5 : 0;
    assert.equal(p.mode, mode, String(kind)); assert.equal(p.action, mode === 0 ? 0 : 3);
  }
  assert.equal(plan(request(26, [], [], 1)).action, 2);
  assert.equal(plan(request(44, [], [], 1)).action, 2);
  assert.equal(plan(request(44, [{}])).mode, 6);
  assert.equal(plan(request(42, [{}])).mode, 0);
  assert.equal(plan(request(42, [{}], [], 16)).mode, 6);
});
test("depth authored height virtualized containers and closed accordions short circuit measurements", () => {
  const values = [240, 90, 20, 60, 3, 5, 7, 11, 8, 24, 24, 52, 999, 37];
  const children = [{ height: 1000 }];
  assert.equal(plan(request(2, children, values)).height, 60);
  assert.equal(plan(request(2, children, values, 0, 1, 32)).height, 37);
  values[1] = 0;
  for (const kind of [2, 4, 5, 7, 24, 25]) assert.equal(plan(request(kind, children, values, 2)).height, 37);
  const closed = plan(request(14, children, values)); assert.equal(closed.action, 4); assert.equal(closed.height, 42); assert.deepEqual(closed.widths, [0]);
});
test("column flow ordering gaps padding and bounds retain exact composition", () => {
  const values = [240, 0, 0, 0, 3, 5, 7, 11, 2.125];
  const p = plan(request(2, [{ height: 20 }, { flags: 0, height: 900 }, { height: 30 }], values));
  assert.equal(p.height, 70.125); assert.equal(p.inner, 232); assert.deepEqual(p.widths, [232, 0, 232]);
  assert.equal(plan(request(2, [], values)).height, 18);
  values[2] = 100; values[3] = 50; assert.equal(plan(request(2, [{ height: 30 }], values)).height, 100);
});
test("authored widths and row bubble queries select actual measurement widths", () => {
  const children = [{ authored: 80 }, { flags: 3 }, { flags: 7, resolved: 112 }, { flags: 0 }];
  const p = plan(request(2, children)); assert.deepEqual(p.widths, [80, 0, 112, 0]); assert.deepEqual(p.queries, [0, 2, 0, 0]);
  const row = plan(request(1, [{ authored: 200 }, { flags: 5, authored: 200, resolved: 60 }]));
  assert.deepEqual(row.queries, [1, 0]); assert.deepEqual(row.widths, [0, 60]);
  children[1] = { flags: 3, authored: 17 }; assert.equal(plan(request(2, children)).widths[1], 17);
});
test("span paragraph height comes from native measurement then applies padding and constraints", () => {
  const p = plan(request(26, [{ height: 999 }], [240, 0, 20, 100, 3, 5, 7, 11, 0, 24, 24, 52, 50], 1));
  assert.equal(p.action, 2); assert.equal(p.inner, 232); assert.equal(p.height, 68); assert.deepEqual(p.widths, [0]);
});
test("alert title indent description gap and chrome floor retain separate contracts", () => {
  const values = [240, 0, 0, 0, 3, 5, 7, 11, 0, 24, 24, 52, 0, 0, 12, 4];
  const p = plan(request(17, [{ height: 60 }, { authored: 300, height: 20 }], values, 4));
  assert.deepEqual(p.widths, [208, 300]); assert.equal(p.height, 106);
  assert.equal(plan(request(17, [], values, 4)).height, 52);
  assert.equal(plan(request(17, [{ height: 60 }], values)).height, 78);
});
test("accordion open empty closed and hidden content widths preserve pose parity", () => {
  const values = [240, 0, 0, 0, 3, 5, 7, 11, 8, 32];
  assert.equal(plan(request(14, [{ height: 60 }], values, 8)).height, 118);
  assert.equal(plan(request(14, [], values, 8)).height, 50);
  values[1] = 900; values[2] = 1000; values[3] = 1;
  const hidden = plan(request(14, [{ authored: 80, height: 60 }, { height: 70 }], values, 0, 2, 90));
  assert.deepEqual(hidden.widths, [80, 240]); assert.equal(hidden.height, 70);
});
test("wrapped arithmetic preserves f32 rounding nonfinite extrema and signed zero", () => {
  assert.equal(plan(request(2, [{ height: 16777216 }, { height: 1 }, { height: 1 }])).height, 16777216);
  assert.equal(plan(request(0, [{ height: NaN }, { height: 30 }])).height, 30);
  assert.equal(plan(request(2, [{ height: 20 }], [NaN, 0, 3, 40, NaN])).inner, 0);
  const negativeZero = plan(request(31, [], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -0])); assert.ok(Object.is(negativeZero.height, -0));
});
test("wrapped records reject truncation surplus unknown kinds flags operations and child lanes", () => {
  for (const op of [0, 1, 2]) {
    const q = request(14, [{}], [], 8, op);
    for (let n = 1; n < q.length; n++) assert.throws(() => native_window_policy(q.subarray(0, n)), /wrapped/);
    assert.throws(() => native_window_policy(new Uint8Array([...q, 0])), /wrapped/);
    for (const at of [1, 2, 3, 4, 80]) { const bad = q.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad), /wrapped/); }
  }
  assert.throws(() => native_window_policy(request(2, [], [], 0, 2)), /wrapped/);
});
test("large recursive measurement batches retain owned output bytes and byte-offset views", () => {
  const q = request(2, Array.from({ length: 256 }, (_, i) => ({ height: i + 1 }))), padded = new Uint8Array(q.length + 17); padded.set(q, 9);
  const result = native_window_policy(padded.subarray(9, 9 + q.length)), saved = result.slice();
  assert.equal(new DataView(result.buffer).getFloat32(12, true), 32896);
  assert.deepEqual(result, native_window_policy(q)); padded.fill(0); native_window_policy(request(14)); assert.deepEqual(result, saved);
});
