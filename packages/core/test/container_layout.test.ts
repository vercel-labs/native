import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

type Child = { flags?: number; grow?: number; main?: number; cross?: number; offsetMain?: number; offsetCross?: number;
  minMain?: number; maxMain?: number; minCross?: number; maxCross?: number; measuredMain?: number; measuredCross?: number };
function request(children: Child[], { op = 1, axis = 0, main = 0, cross = 0, x = 0, y = 0, width = 300, height = 80, gap = 10 } = {}): Uint8Array {
  const b = new Uint8Array(36 + children.length * 48), d = new DataView(b.buffer);
  b.set([5, op, axis, main, cross]); d.setUint32(8, children.length, true);
  [x, y, width, height, gap].forEach((v, i) => d.setFloat32(12 + i * 4, v, true));
  children.forEach((c, i) => {
    const at = 36 + i * 48; d.setUint32(at, c.flags ?? 1, true);
    [c.grow, c.main, c.cross, c.offsetMain, c.offsetCross, c.minMain, c.maxMain, c.minCross, c.maxCross, c.measuredMain, c.measuredCross]
      .forEach((v, n) => d.setFloat32(at + 4 + n * 4, v ?? 0, true));
  }); return b;
}
function result(b: Uint8Array) {
  const d = new DataView(b.buffer, b.byteOffset, b.byteLength), count = d.getUint32(0, true);
  return { used: d.getFloat32(4, true), overflow: d.getFloat32(8, true), frames: Array.from({ length: count }, (_, i) =>
    Array.from({ length: 4 }, (_, n) => d.getFloat32(12 + i * 16 + n * 4, true))) };
}
test("container allocation keeps grow floors and ceilings without redistributing capped share", () => {
  assert.deepEqual(result(native_window_policy(request([{ grow: 1, minMain: 20, maxMain: 50 }, { grow: 1 }], { main: 1 }))),
    { used: 205, overflow: 0, frames: [[47.5, 0, 50, 80], [107.5, 0, 145, 80]] });
  const q = request([{ main: 40 }, { main: 40 }, { main: 40 }], { main: 3, gap: 0 });
  assert.deepEqual(result(native_window_policy(q)).frames.map(f => f[0]), [0, 130, 260]);
});
test("cross placement centers intrinsic overflow and applies authored offsets", () => {
  assert.deepEqual(result(native_window_policy(request([{ main: 60, measuredCross: 120, offsetCross: 3 }], { cross: 2 }))).frames,
    [[0, -17, 60, 120]]);
  assert.deepEqual(result(native_window_policy(request([{ main: 60, measuredCross: 120 }], { cross: 3 }))).frames, [[0, 0, 60, 80]]);
  const q = request([{ grow: 1, measuredCross: 60, offsetCross: 3 }], { axis: 1, cross: 2 });
  assert.deepEqual(result(native_window_policy(q)).frames, [[123, 0, 60, 80]]);
});
test("native measurement widths and layout share implicit tabs and bubble allocation", () => {
  const children = [{ flags: 3, main: 40 }, { grow: 1, minMain: 40 }];
  assert.equal(result(native_window_policy(request(children))).frames[0]![2], 290);
  const widths = result(native_window_policy(request(children, { op: 2 }))).frames.map(f => f[2]);
  assert.deepEqual(widths, [290, 40]);
  const bubble = [{ flags: 9, measuredMain: 500, measuredCross: 500 }];
  assert.equal(result(native_window_policy(request(bubble, { width: 200 }))).frames[0]![2], 160);
  assert.equal(result(native_window_policy(request(bubble, { width: 200, axis: 1 }))).frames[0]![2], 160);
});
test("semantic kind facts leave authored sizes bounds and numeric eligibility to TypeScript", () => {
  assert.deepEqual(result(native_window_policy(request([{ flags: 3, grow: 1, main: 40 }, { main: 50 }]))).frames.map(f => f[2]), [240, 50]);
  assert.equal(result(native_window_policy(request([{ flags: 9, main: 500 }], { width: 20 }))).frames[0]![2], 500);
  assert.equal(result(native_window_policy(request([{ flags: 9, measuredMain: 500, maxMain: 40 }], { width: 20 }))).frames[0]![2], 40);
  assert.equal(result(native_window_policy(request([{ flags: 9, measuredCross: 500, maxCross: 40 }], { width: 20, axis: 1 }))).frames[0]![2], 20);
  assert.equal(result(native_window_policy(request([{ flags: 1, measuredMain: 500 }], { width: 20 }))).frames[0]![2], 500);
});
test("cross pass resolves actual wrap widths before receiving measured heights", () => {
  const q = request([{ measuredCross: 500, flags: 9 }, { cross: 48, minCross: 64 }, { flags: 0 }], { op: 0, axis: 1, width: 200 });
  const out = native_window_policy(q), d = new DataView(out.buffer);
  assert.equal(out.length, 24); assert.deepEqual([12, 16, 20].map(at => d.getFloat32(at, true)), [160, 64, 0]);
  q[1] = 1; new DataView(q.buffer).setFloat32(76, 60, true);
  assert.equal(result(native_window_policy(q)).frames[0]![3], 60);
});
test("stack frames preserve offsets constraints and full-width tabs", () => {
  assert.deepEqual(result(native_window_policy(request([{ main: 40, cross: 20, offsetMain: 8, offsetCross: 4, flags: 3 }], { op: 3, x: 10, y: 20 }))).frames,
    [[18, 24, 292, 20]]);
  assert.equal(result(native_window_policy(request([{ main: 400, flags: 3, maxMain: 350 }], { op: 3 }))).frames[0]![2], 350);
});
test("flow excludes hoisted surfaces and preserves the overflow diagnostic tolerance", () => {
  const children = [{ main: 100 }, { flags: 0, main: 900 }, { main: 100 }];
  assert.equal(result(native_window_policy(request(children, { width: 150 }))).overflow, 60);
  assert.equal(result(native_window_policy(request(children, { width: 209.5 }))).overflow, 0);
  assert.equal(result(native_window_policy(request(children, { width: 209.49 }))).overflow > 0.5, true);
  assert.equal(result(native_window_policy(request(children, { width: Infinity }))).overflow, 0);
  assert.equal(result(native_window_policy(request(children, { width: 0 }))).overflow, 210);
  assert.equal(Number.isNaN(result(native_window_policy(request(children, { width: NaN }))).overflow), true);
  assert.deepEqual(result(native_window_policy(request([]))).frames, []);
});
test("container records reject every truncation extra byte invalid enum and reserved lane", () => {
  for (const valid of [request([]), request([{}]), request([{}], { op: 0 }), request([{}], { op: 3 })]) {
    for (let n = 1; n < valid.length; n++) assert.throws(() => native_window_policy(valid.subarray(0, n)), /container/);
    assert.throws(() => native_window_policy(new Uint8Array([...valid, 0])), /container/);
    for (const at of [1, 2, 3, 4, 5, 6, 7, 8, 32]) { const q = valid.slice(); q[at] = 255; assert.throws(() => native_window_policy(q), /container/); }
    if (valid.length > 36) { const q = valid.slice(); q[36] = 255; assert.throws(() => native_window_policy(q), /container/); }
  }
});
test("container results own bytes across subviews later calls and input mutation", () => {
  const q = request(Array.from({ length: 128 }, (_, i) => ({ main: i + 1 }))), padded = new Uint8Array(q.length + 13);
  padded.set(q, 7); const out = native_window_policy(padded.subarray(7, 7 + q.length)), saved = out.slice();
  assert.deepEqual(out, native_window_policy(q)); padded.fill(0); native_window_policy(request([{}], { op: 3 })); assert.deepEqual(out, saved);
});
