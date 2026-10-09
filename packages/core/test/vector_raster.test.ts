import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "render_resources.ts", "vector_raster.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvVectorRaster: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvVectorRaster};").toString("base64")}`);
function geometry(capacity = 4096, stroke = false): Uint8Array {
  const points = [[0, 1.25, 1.25], [1, 5.75, 1.25], [1, 5.75, 5.75], [1, 1.25, 5.75], [4, 0, 0]];
  const bytes = new Uint8Array(96 + points.length * 28), w = new DataView(bytes.buffer);
  bytes.set([66, 1, stroke ? 1 : 0, 5]); w.setUint32(4, points.length, true); w.setUint32(8, capacity, true); w.setUint32(16, 48, true);
  w.setFloat32(24, 0.25, true); w.setFloat32(28, 1, true); w.setFloat32(32, 4, true); w.setFloat32(48, 1, true); w.setFloat32(60, 1, true);
  points.forEach(([verb, x, y], i) => { w.setUint32(96 + i * 28, verb!, true); w.setFloat32(100 + i * 28, x!, true); w.setFloat32(104 + i * 28, y!, true); });
  return bytes;
}
function sweep(edges: Uint8Array, rule = 0, capacity = 256, band = false): Uint8Array {
  const facts = new DataView(edges.buffer, edges.byteOffset, edges.byteLength), count = facts.getUint32(4, true), bytes = new Uint8Array(80 + count * 20), w = new DataView(bytes.buffer);
  bytes.set([66, 1, band ? 3 : 2, 5]); w.setUint32(4, count, true); w.setUint32(8, capacity, true); w.setUint32(12, rule, true);
  bytes.set(edges.subarray(8, 24), 16); w.setInt32(40, 8, true); w.setInt32(44, 8, true);
  if (band) { w.setInt32(48, 1, true); w.setUint32(52, 5, true); }
  bytes.set(edges.subarray(32), 80); return bytes;
}
function checked(bytes: Uint8Array): Uint8Array {
  const before = bytes.slice(), result = plan(bytes); assert.deepEqual(bytes, before); assert.deepEqual(result, dispatch(bytes));
  const backing = new Uint8Array(bytes.length + 23); backing.set(bytes, 11);
  assert.deepEqual(result, plan(backing.subarray(11, 11 + bytes.length)));
  const copy = result.slice(); bytes.fill(255); assert.deepEqual(result, copy); return result;
}
test("vector raster preserves fill edges and all capacity prefixes with copied ownership", () => {
  const complete = checked(geometry()), w = new DataView(complete.buffer); assert.equal(w.getUint32(4, true), 2);
  assert.deepEqual(Array.from({ length: 4 }, (_, i) => w.getFloat32(8 + i * 4, true)), [1.25, 1.25, 5.75, 5.75]);
  for (let capacity = 0; capacity <= 3; capacity++) {
    const result = checked(geometry(capacity)), out = new DataView(result.buffer);
    assert.equal(out.getUint32(0, true), capacity < 2 ? 1 : 0); assert.equal(out.getUint32(4, true), Math.min(capacity, 2));
    assert.deepEqual(result.subarray(32), complete.subarray(32, 32 + Math.min(capacity, 2) * 20));
  }
  assert.ok(new DataView(checked(geometry(4096, true)).buffer).getUint32(4, true) > 2);
});
test("vector raster emits exact fractional rectangle coverage for both fill rules", () => {
  const edges = plan(geometry());
  for (const rule of [0, 1]) {
    const header = checked(sweep(edges, rule)), h = new DataView(header.buffer); assert.deepEqual([h.getInt32(8, true), h.getInt32(12, true), h.getInt32(16, true), h.getInt32(20, true)], [1, 1, 6, 6]);
    const result = checked(sweep(edges, rule, 256, true)), w = new DataView(result.buffer); assert.equal(w.getUint32(4, true), 5);
    for (let y = 0; y < 5; y++) for (let x = 0; x < 5; x++) assert.equal(w.getFloat32(32 + (y * 5 + x) * 4, true), (x === 0 || x === 4 ? 0.75 : 1) * (y === 0 || y === 4 ? 0.75 : 1));
    const failed = checked(sweep(edges, rule, 1, true)); assert.equal(new DataView(failed.buffer).getUint32(0, true), 1); assert.equal(failed.length, 32);
  }
});
test("vector raster retains accumulated edges and stale empty bounds", () => {
  const prefix = plan(geometry()), w = new DataView(prefix.buffer), bytes = geometry(4096), extend = new Uint8Array(bytes.length + prefix.length - 32), e = new DataView(extend.buffer);
  extend.set(bytes); e.setUint32(12, w.getUint32(4, true), true); extend.set(prefix.subarray(8, 24), 72); extend.set(prefix.subarray(32), bytes.length);
  const result = checked(extend), r = new DataView(result.buffer); assert.equal(r.getUint32(4, true), 4); assert.deepEqual(result.subarray(32, 72), prefix.subarray(32));
  const empty = new Uint8Array(96), h = new DataView(empty.buffer); empty.set([66, 1, 0, 5]); h.setUint32(16, 48, true); h.setFloat32(72, -0, true); h.setFloat32(76, 99, true);
  const stale = empty.slice(72, 88); assert.deepEqual(checked(empty).subarray(8, 24), stale);
});
test("vector raster rejects malformed versions verbs dimensions and coverage bands", () => {
  const bytes = geometry();
  for (const length of [0, 3, 95, 96, bytes.length - 1]) assert.throws(() => plan(bytes.subarray(0, length)), /invalid|truncated/);
  for (const [at, value] of [[4, 4294967295], [8, 18561], [12, 4097], [16, 49], [20, 1], [36, 2], [40, 2], [96, 5]]) {
    const bad = bytes.slice(); new DataView(bad.buffer).setUint32(at!, value!, true); assert.throws(() => plan(bad), /invalid/);
  }
  const edges = plan(bytes), band = sweep(edges, 0, 256, true);
  for (const [at, value] of [[4, 18561], [8, 18561], [12, 2], [48, 0], [52, 0], [52, 17], [56, 1]]) {
    const bad = band.slice(); new DataView(bad.buffer).setUint32(at!, value!, true); assert.throws(() => plan(bad), /invalid/);
  }
});
